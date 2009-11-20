package Pyro::Hook;
use Any::Moose;
use overload
    '&{}' => sub {
        my $self = shift;
        return sub { $self->execute() }
    },
    fallback => 1,
;

has callbacks => (
    traits => ['Array'],
    is => 'ro',
    isa => 'ArrayRef',
    lazy_build => 1,
    handles => {
        unshift_callback => 'unshift',
        add_callback => 'push',
        all_callbacks => 'elements',
        get_callback_at => 'get',
    }
);

sub _build_callbacks { [] }

sub execute {
    my $self = shift;
    foreach my $callback ( $self->all_callbacks ) {
        $callback->();
    }
}

__PACKAGE__->meta->make_immutable();

# don't use namespace::clean with use overload
no Moose;

1;

