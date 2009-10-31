package App::Pyro;
use Moose;
use Pyro;
use namespace::clean -excetp => qw(meta);

with qw(MooseX::Getopt MooseX::SimpleConfig);

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

    my $pyro = Pyro->new(%config);
    $pyro->start();
}

1;