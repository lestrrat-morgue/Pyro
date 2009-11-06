package Pyro::Proxy::Server;
use Moose;
use Coro;
use Coro::EV;
use Coro::AnyEvent;
use AnyEvent::Socket;
use namespace::clean -except => qw(meta);

has host => (
    is => 'ro',
);

has listen_size => (
    is => 'ro',
    isa => 'Int',
    default => 128,
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
    my $client = Pyro::Proxy::Client->new(
        server => $self,
    );

    my $incoming_cb = sub {
        my ($socket, $host, $port) = @_;
        $client->process_connection( $socket, $context );
    };

    my $prepare_cb = sub {
        return $self->listen_size;
    };

    my $guard = tcp_server $self->host, $self->port, $incoming_cb, $prepare_cb;
    $self->set_tcp_server_guard($guard);
}

__PACKAGE__->meta->make_immutable();

1;

