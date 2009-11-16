package Pyro::Service::ForwardProxy;
use Moose;
use Pyro::Service::ForwardProxy::Server;
use namespace::clean -except => qw(meta);

extends 'Pyro::Service';

has host => (
    is => 'ro',
    default => '0.0.0.0',
);

has port => (
    is => 'ro',
    default => 8888
);

sub start {
    my ($self, $context) = @_;
    my $host_port = join(':', $self->host, $self->port);
    $context->log->info( "Starting Pyro ForwardProxy Service on $host_port\n" );

    Pyro::Service::ForwardProxy::Server->new(
        host => $self->host,
        port => $self->port,
        context => $context,
    )->start();
}

__PACKAGE__->meta->make_immutable();

1;

