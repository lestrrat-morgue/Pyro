package Pyro::Service::ForwardProxy;
use Any::Moose;
use Pyro::Service::ForwardProxy::Server;
use namespace::clean -except => qw(meta);

extends 'Pyro::Service';

has server_args => (
    is => 'ro',
    isa => 'HashRef',
    default => sub { +{} }
);

around BUILDARGS => sub {
    my ($next, $class, @args) = @_;
    my $args = $next->($class, @args);
    return { server_args => $args };
};

sub start {
    my ($self, $context) = @_;

    Pyro::Service::ForwardProxy::Server->new(
        %{ $self->server_args }, context => $context
    )->start();
}

__PACKAGE__->meta->make_immutable();

1;

