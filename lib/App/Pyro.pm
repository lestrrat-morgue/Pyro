package App::Pyro;
use Moose;
use Pyro;
use namespace::clean -excetp => qw(meta);

with qw(MooseX::Getopt MooseX::SimpleConfig);

has cache_servers => (
    is => 'ro',
    isa => 'ArrayRef',
    predicate => 'has_cache_servers',
);

has config => (
    is => 'ro',
    isa => 'HashRef',
    predicate => 'has_config',
);

has listen => (
    is => 'ro',
    isa => 'Str',
);

sub run {
    my $self = shift;

    my %config = $self->has_config ? %{ $self->config } : ();

    if (my $listen = $self->listen) {
        if ($listen =~ s/:(\d+)$//) {
            $config{port} = $1;
        }
        $config{host} = $listen;
    }

    $config{port} ||= 8080;

    if ( $self->has_cache_servers ) {
        $config{cache} = Pyro::Cache->new(
            cache_servers => $self->cache_servers,
        );
    }

    my $condvar = AnyEvent->condvar;
    $config{condvar} = $condvar;
    my $pyro = Pyro->new(%config);
    $pyro->start();
    $condvar->recv;
}

1;