package Pyro;
use Moose;
use AnyEvent;
use Pyro::Cache;
use Pyro::Log;
use Pyro::Proxy::Client;
use Pyro::Proxy::Server;
use namespace::clean -except => qw(meta);

our $VERSION = '0.00001';

has host => (
    is => 'ro',
    default => '0.0.0.0',
);

has port => (
    is => 'ro',
    default => 8888
);

has clients => (
    traits => ['Array'],
    is => 'ro',
    isa => 'ArrayRef',
    lazy_build => 1,
    handles => {
        add_client => 'push',
    }
);

has server => (
    is => 'ro',
    isa => 'Pyro::Proxy::Server',
    lazy_build => 1,
);

has log => (
    is => 'ro',
    isa => 'Pyro::Log',
    lazy_build => 1,
);

sub _build_clients { [] }
sub _build_log {
    return Pyro::Log->new();
}
sub _build_server {
    my $self = shift;
    return Pyro::Proxy::Server->new(
        host => $self->host,
        port => $self->port,
    );
}

sub start {
    my $self = shift;
    my $server = $self->server;
    $server->start($self);

    print "Starting Pyro/$VERSION on ", $self->host, ':',  $self->port, "\n";
    my $cv = AnyEvent->condvar;
    $SIG{INT} = sub {
        print STDERR "Received SIGINT";
        $cv->send;
    };
    $cv->recv;
}

__PACKAGE__->meta->make_immutable();

1;

