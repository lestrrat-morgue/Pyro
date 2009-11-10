package Pyro;
use Moose;
use AnyEvent;
use Pyro::Cache;
use Pyro::Log;
use Pyro::Proxy::Client;
use Pyro::Proxy::Server;
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

sub _build_server {
    my $self = shift;
    return Pyro::Proxy::Server->new(
        host => $self->host,
        port => $self->port,
    );
}

sub start {
    my $self = shift;

    my $host_port = join(':', $self->host, $self->port);
    $self->log->info( "Starting Pyro/$VERSION on $host_port\n" );

    my $cv = $self->condvar;
    $cv->begin;
    local %SIG;
    foreach my $sig qw(INT HUP QUIT TERM) {
        $SIG{$sig} = sub {
#            print STDERR "Received SIG$sig";
            $cv->end;
        };
    }

    my $server = $self->server;
    $server->start($self);
}

__PACKAGE__->meta->make_immutable();

1;

