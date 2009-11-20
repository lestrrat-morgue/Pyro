package Pyro::PreforkServer;
use Any::Moose '::Role';
use Socket qw(AF_INET AF_UNIX SOCK_STREAM SOL_SOCKET SO_REUSEADDR);
use AnyEvent;
use AnyEvent::Handle;
use AnyEvent::Socket qw(address_family parse_address format_address);
use AnyEvent::Util qw(AF_INET6 fh_nonblocking);
use POSIX qw(WNOHANG);
use namespace::clean -except => qw(meta);

has concurrency => (
    is => 'ro',
    isa => 'Int',
    default => 10
);

has host => (
    is => 'ro',
);

has listen_queue => (
    is => 'ro',
    isa => 'Int',
    default => 128,
);

has max_connections_per_child => (
    is => 'ro',
    isa => 'Int',
    default => 10
);

has port => (
    is => 'ro',
    default => 8888
);

has on_stop => (
    is => 'ro',
    isa => 'CodeRef',
    lazy_build => 1,
    required => 1,
);

after start => sub {
    my ($self, $context) = @_;

    my $host = $self->host;
    my $service = $self->port;

    $context->log->info( "Starting Pyro " . 
        do { my $x = blessed $self; $x =~ s/^Pyro::Server:://; $x } .
        " Service on $host:$service\n" );

    # Most of below are taken from AnyEvent::Socket, with some modifications
    if (! defined $host) {
        $host = 
            $AnyEvent::PROTOCOL{ipv4} < $AnyEvent::PROTOCOL{ipv6} && 
            AF_INET6 ? "::" : "0"
    }
    my $ipn = parse_address $host
        or Carp::croak __PACKAGE__ . ": cannot parse '$host' as host address";

    my $af = address_family $ipn;

    # win32 perl is too stupid to get this right :/
    Carp::croak "tcp_server/socket: address family not supported"
        if AnyEvent::WIN32 && $af == AF_UNIX;

    my $socket;
    socket $socket, $af, SOCK_STREAM, 0
        or Carp::croak "tcp_server/socket: $!";

    if ($af == AF_INET || $af == AF_INET6) {
        setsockopt $socket, SOL_SOCKET, SO_REUSEADDR, 1
            or Carp::croak "tcp_server/so_reuseaddr: $!"
            unless AnyEvent::WIN32; # work around windows bug

        unless ($service =~ /^\d*$/) {
                $service = (getservbyname $service, "tcp")[2]
                     or Carp::croak "$service: service unknown"
        }
    } elsif ($af == AF_UNIX) {
        unlink $service;
    }

    bind $socket, AnyEvent::Socket::pack_sockaddr($service, $ipn)
        or Carp::croak "bind: $!";

    fh_nonblocking($socket, 1);
    listen $socket, $self->listen_queue
        or Carp::croak "listen: $!";

    my %children;
    local %SIG;
    foreach my $sig qw(INT HUP QUIT TERM) {
        $SIG{$sig} = sub {
            foreach my $pid (keys %children) {
                print "Received $sig: Killing $pid\n";
                kill TERM => $pid;
            }
        }
    };

    $context->log->debug( sprintf("Concurrency level is %d\n", $self->concurrency ) );
    for(1..$self->concurrency) {
        my $pid = fork();
        die unless defined $pid;
        if ($pid) {
            $children{$pid} = 1;
        } else {
            local %SIG;

            # main condvar. if you send() anywhere in the child process, the
            # child process will eventually exit.
            my $main_cv = AE::cv {
                undef $socket;
                exit 0;
            };
            $SIG{TERM} = sub { $main_cv->send };

            # We want to handle N at a time, so we keep canceling $w
            # when we reach the maximum.
            my $w;
            my $process_cb;
            my $current = 0;
            my $max = $self->max_connections_per_child;
            $context->log->debug( "child process: max connections: $max\n" );

            $process_cb = sub {
                return unless $socket;

                my $fh;
                my $peer = accept $fh, $socket;
                return unless $peer;

                $current++;
                if ($current == $max) {
                    $context->log->debug( "max connection reached ($max). stopping watcher...\n");
                    undef $w;
                }
                my $cv = AE::cv;
                $cv->begin( sub {
                    $current--;
                    if (! $w && $current <= int($max * 0.80)) {
                        $context->log->debug( "restarting watcher ($current).\n");
                        $w = AE::io $socket, 0, $process_cb;
                    }
                });

                AE::now_update;
                fh_nonblocking($fh, 1); 

                # consumers of this module must receive this $cv, and call
                # ->end() when they are done with whatever they were doing
                $self->process_connection( $fh, $context, $cv );
            };
            $w = AE::io $socket, 0, $process_cb;
            $main_cv->recv;
            exit 1;
        }
    }

    foreach my $childpid (keys %children) {
        my $chld; $chld = AE::child $childpid, sub {
            delete $children{$childpid};
            undef $chld;
            $self->on_stop->() if scalar keys %children == 0;
        };
    }
};

sub _build_on_stop {
    my $self = shift;
    return sub { $self->context->stop };
}

1;

__END__

=head1 NAME

Pyro::PreforkServer - Role That Adds Prefork -> AnyEvent Loop

=cut
