package Pyro::Service::ForwardProxy::Server;
use Any::Moose;
use Pyro::Service::ForwardProxy::Client;
use namespace::clean -except => qw(meta);

with 'Pyro::PreforkServer';

has client => (
    is => 'ro',
    isa => 'Pyro::Service::ForwardProxy::Client',
    lazy_build => 1,
);

has context => (
    is => 'ro',
    required => 1,
);

before start => sub {
    my $self = shift;
    my $host_port = join(':', $self->host, $self->port);
    $self->context->log->info( "Starting Pyro ForwardProxy Service on $host_port\n" );
};

sub _build_client {
    return Pyro::Service::ForwardProxy::Client->new();
}

sub _build_on_accept {
    my $self = shift;
    return sub {
        my $handle = shift;
        $self->client->process_connection( $handle, $self->context );
    }
}

sub _build_on_stop {
    my $self = shift;
    return sub { $self->context->stop };
}

__PACKAGE__->meta->make_immutable();

1;

