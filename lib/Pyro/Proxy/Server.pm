package Pyro::Proxy::Server;
use Moose;
use Coro;
use Coro::AnyEvent;
use AnyEvent::Socket;
use namespace::clean -except => qw(meta);

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

sub start {
    my ($self, $context) = @_;
    my $cache = Pyro::Cache->new();

    my $guard = tcp_server $self->host, $self->port, sub {
        my ($socket, $host, $port) = @_;
        my $client = Pyro::Proxy::Client->new(
            handle      => $socket,
            remote_host => $host,
            remote_port => $port,
            hcache      => $cache,
        );
        $client->start($context);
    };
    $self->set_tcp_server_guard($guard);
}

__PACKAGE__->meta->make_immutable();

1;

