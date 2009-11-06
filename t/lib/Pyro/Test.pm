package Pyro::Test;
use strict;
use base qw(Exporter);
use AnyEvent::HTTP;
our @EXPORT = qw(test_proxy http_get http_post);

sub test_proxy {
    my %args = @_;

    my $self = Pyro::Test::Context->new(%args);
    
    $self->start_server();
    $self->start_proxy();
    $self->run_client();
}

package #
    Pyro::Test::Context;
use Moose;
use Pyro;
use Plack;
use Plack::Loader;
use Plack::Request;
use Config;
use IO::Socket::INET;
use POSIX;
use Test::SharedFork;
use Test::More ();
use namespace::clean -except => qw(meta);

has client => (
    is => 'ro',
    isa => 'CodeRef',
    required => 1,
);

has proxy => (
    is => 'ro',
    isa => 'CodeRef',
    lazy_build => 1,
);

has proxy_pid => (
    is => 'rw',
    isa => 'Int',
);

has proxy_port => (
    is => 'ro',
    isa => 'Int',
    lazy_build => 1,
);

has server => (
    is => 'ro',
    isa => 'CodeRef',
    required => 1,
);

has server_pid => (
    is => 'rw',
    isa => 'Int',
);

has server_port => (
    is => 'ro',
    isa => 'Int',
    lazy_build => 1,
);

sub _build_proxy {
    my $self = shift;
    return sub {
        my %args = ( port => $self->proxy_port );

        my $memcached_class;
        foreach my $class qw(Cache::Memcached Cache::Memcached::Fast Cache::Memcached::libmemcached) {
            if (! Class::MOP::is_class_loaded($class) ) {
                eval { Class::MOP::load_class($class) };
                if (!$@) {
                    $memcached_class = $class;
                    last;
                }
            }
        }
        if ($memcached_class) {
            my $sock = IO::Socket::INET->new(
                PeerHost => '127.0.0.1',
                PeerPort => '11211',
            );
            if ($sock) {
                $args{cache} = $memcached_class->new({
                    servers => [ '127.0.0.1:11211' ],
                    compress_threshold => 10_000
                });
            }
        }

        Pyro->new(%args)->start
    };
}

sub _build_proxy_port {
    my $self = shift;
    return empty_port( $self->server_port + 1 );
}

sub _build_server_port {
    return empty_port();
}

# process does not die when received SIGTERM, on win32.
my $TERMSIG = $^O eq 'MSWin32' ? 'KILL' : 'TERM';

sub empty_port {
    my $port = shift || 10000;
    $port = 19000 unless $port =~ /^[0-9]+$/ && $port < 19000;

    while ( $port++ < 20000 ) {
        my $sock = IO::Socket::INET->new(
            Listen    => 5,
            LocalAddr => '127.0.0.1',
            LocalPort => $port,
            Proto     => 'tcp',
            ReuseAddr => 1,
        );
        return $port if $sock;
    }
    die "empty port not found";
}

sub start_server {
    my $self = shift;
    my $port = $self->server_port();
    my $pid = Test::SharedFork->fork();
    if ($pid) {
        $self->server_pid($pid);
        return; # parent, which should be the client
    }

    my $plack = Plack::Loader->load("Standalone", port => $port);
    $plack->run( $self->server );
    exit;
}

sub start_proxy {
    my $self = shift;
    my $port = $self->proxy_port();
    my $pid = Test::SharedFork->fork();
    if ($pid) {
        $self->proxy_pid($pid);
        return; # parent, which should be the client
    }

    $self->proxy->( $port );
    exit;
}

sub run_client {
    my $self = shift;

    wait_port($self->proxy_port);
    wait_port($self->server_port);

    my $sig;
    my $err;
    {
        local $SIG{INT}  = sub { $sig = "INT"; die "SIGINT received\n" };
        local $SIG{PIPE} = sub { $sig = "PIPE"; die "SIGPIPE received\n" };
        eval {
            $self->client->(
                proxy_pid   => $self->proxy_pid,
                proxy_port  => $self->proxy_port,
                server_pid  => $self->server_pid,
                server_port => $self->server_port,
            );
        };
        $err = $@;

        # cleanup
        foreach my $pid ($self->proxy_pid, $self->server_pid) {
            kill $TERMSIG => $pid;
            while (1) {
                my $kid = waitpid( $pid, 0 );
                if ($^O ne 'MSWin32') { # i'm not in hell
                    if (WIFSIGNALED($?)) {
                        my $signame = (split(' ', $Config{sig_name}))[WTERMSIG($?)];
                        if ($signame =~ /^(ABRT|PIPE)$/) {
                            Test::More::diag("your server received SIG$signame");
                        }
                    }
                }
                if ($kid == 0 || $kid == -1) {
                    last;
                }
            }
        }
    }

    if ($sig) {
        kill $sig, $$; # rethrow signal after cleanup
    }
    if ($err) {
        die $err; # rethrow exception after cleanup.
    }
}

sub _check_port {
    my ($port) = @_;

    my $remote = IO::Socket::INET->new(
        Proto    => 'tcp',
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
    );
    if ($remote) {
        close $remote;
        return 1;
    }
    else {
        return 0;
    }
}

sub wait_port {
    my $port = shift;

    my $retry = 10;
    while ( $retry-- ) {
        return if _check_port($port);
        sleep 1;
    }
    die "cannot open port: $port";
}

__PACKAGE__->meta->make_immutable();

1;

__END__

=head1 NAME

Pyro::Test

=head1 SYNOPSIS

    use Pyro::Test;
    test_proxy(
        server => ,
        proxy  => ,
        client => ,
    );

=cut
