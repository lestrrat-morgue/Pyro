package Pyro::Proxy::Server;
use Moose;
use Coro;
use Coro::AnyEvent;
use AnyEvent::Socket;
use namespace::clean -except => qw(meta);

has hcache => (
    is => 'ro',
    isa => 'Pyro::Cache',
    lazy_build => 1,
);

has host => (
    is => 'ro',
);

has port => (
    is => 'ro',
    default => 8888
);

has tcp_server_guard => (
    is => 'ro',
    writer => 'set_tcp_server_guard'
);

sub _build_hcache { Pyro::Cache->new() }

sub start {
    my ($self, $context) = @_;
    my $client = Pyro::Proxy::Client->new(
        server => $self,
    );

    my $guard = tcp_server $self->host, $self->port, sub {
        my ($socket, $host, $port) = @_;

        # XXX throttle?
        $client->process_connection( $socket, $context );
    };
    $self->set_tcp_server_guard($guard);
}

__PACKAGE__->meta->make_immutable();

1;

