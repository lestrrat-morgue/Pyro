package Pyro::Service::ForwardProxy::Server;
use Moose;
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

sub _build_client {
    return Pyro::Service::ForwardProxy::Client->new();
}

sub _build_on_accept {
    my $self = shift;
    return sub {
        my $fh = shift;
        $self->client->process_connection( $fh, $self->context );
    }
}

sub _build_on_stop {
    my $self = shift;
    return sub { $self->context->stop };
}

__PACKAGE__->meta->make_immutable();

1;

