package App::Pyro;
use Moose;
use Pyro;
use namespace::clean -excetp => qw(meta);

with qw(MooseX::Getopt MooseX::SimpleConfig);

has debug => (
    is => 'ro',
    isa => 'Bool',
    default => 0,
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

    if ( my $cache_config = delete $config{cache} ) {
        $config{hcache} = Pyro::Cache->new(%$cache_config);
    }

    my @services;
    foreach my $svc ( @{ delete $config{services} || [] }) {
        my $class = delete $svc->{class};
        if ($class !~ s/^\+//) {
            $class = "Pyro::Service::$class";
        }
        if (! Class::MOP::is_class_loaded($class)) {
            Class::MOP::load_class($class);
        }
        push @services, $class->new( %$svc );
    }
    $config{services} = \@services;

    my $condvar = AnyEvent->condvar;
    $config{condvar} = $condvar;
    my $pyro = Pyro->new(%config, debug => $self->debug);
    $pyro->start();
    $condvar->recv;
}

1;