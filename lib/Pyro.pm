package Pyro;
use Moose;
use AnyEvent;
use AnyEvent::Handle;
use Pyro::Cache;
use Pyro::Log;
use namespace::clean -except => qw(meta);

our $VERSION = '0.00001';

has condvar => (
    is => 'ro',
    lazy_build => 1,
);

has debug => (
    is => 'ro',
    isa => 'Bool',
    default => 0
);

has error_log => (
    is => 'ro',
    isa => 'Str',
);

has hcache => (
    is => 'ro',
    isa => 'Pyro::Cache',
);

has services => (
    traits => ['Array'],
    is => 'ro',
    isa => 'ArrayRef[Pyro::Service]',
    required => 1,
    handles => {
        all_services => 'elements',
    }
);

has log => (
    is => 'ro',
    isa => 'Pyro::Log',
    lazy_build => 1,
);

sub _build_condvar { AnyEvent->condvar }
sub _build_log {
    my $self = shift;

    my %log_map = (
        info => [ AnyEvent::Handle->new(fh => \*STDOUT) ],
    );
    # error log will contain real errors and debug messages
    if ($self->error_log) {
        open(my $fh, '>', $self->error_log) or
            confess "Could not open " . $self->error_log . ": $!";
        $log_map{ error } = [ AnyEvent::Handle->new( fh => $fh ) ];
    }

    if ($self->debug) {
        $log_map{ debug } = $log_map{ error } ||
            [ AnyEvent::Handle->new(fh => \*STDERR) ];
    }

    return Pyro::Log->new(log_map => \%log_map)
}

sub start {
    my $self = shift;

    my $cv = $self->condvar;
    $cv->begin;
    local %SIG;
    foreach my $sig qw(INT HUP QUIT TERM) {
        $SIG{$sig} = sub {
#            print STDERR "Received SIG$sig";
            $cv->end;
        };
    }

    foreach my $service ( $self->all_services ) {
        $service->start( $self );
    }
}

sub stop {
    my $self = shift;
    $self->condvar->send;
}

__PACKAGE__->meta->make_immutable();

1;

__END__

=head1 NAME

Pyro - AnyEvent/Moose Powered Proxy-Cache

=head1 SYNOPSIS

    pyro --configfile=/path/to/config.yaml

=head1 DESCRIPTION

B<This is an alpha release>. Pyro in its current form works as a simple HTTP proxy cache, with memcached as its storage.

=head1 ARCHITECTURE

Pyro is a prefork server. The child processes, however, are event based.


=head1 REVERSE PROXY

Put this in front of your servers.

    config:
        cache:
            servers:
                - server1.cache:11211
                - server2.cache:11211
                - server3.cache:11211
                - server4.cache:11211
        services:
            - class: ReverseProxy
              servers:
                - server1
                - server2
                - server3
                - server4

In reverse proxy mode, 

=head1 FORWARD PROXY

Put this in your local machine or some such so, and configure your browsers.

    config:
        cache:
            servers:
                - 127.0.0.1:11211
        services:
            - class: ForwardProxy

=cut
