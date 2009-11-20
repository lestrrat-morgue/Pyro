package Pyro::Handle;
use Any::Moose;
use Any::MooseX::NonMoose;
use namespace::clean -except => qw(meta);

extends 'AnyEvent::Handle';

{
    foreach my $handler qw(on_eof on_error on_timeout on_drain) {
        override $handler => sub {
            if (@_ >= 2) {
                super();
            } else {
                return $_[0]->{$handler};
            }
        };
    
        my $short = $handler;
        $short =~ s/^on_//;
        has $handler => (
            is => 'bare',
            handles => {
                "unshift_${short}_callback" => 'unshift_callback',
                "add_${short}_callback" => 'add_callback',
            }
        );
    }
}

around BUILDARGS => sub {
    my ($next, $class, @args) = @_;
    my $args = $next->($class, @args);

    foreach my $handler qw(on_eof on_error on_timeout on_drain) {
        $args->{$handler} ||= Pyro::Hook->new();
    }

    return $args;
};

sub BUILD {
    my $self = shift;
    my $finalizer = sub {
        if ($self) {
            close($self->fh) if $self->fh;
            $self->destroy();
        }
    };

    foreach my $handler qw(on_eof on_error on_timeout) {
        $self->$handler->add_callback( $finalizer );
    }
    return $self;
};

__PACKAGE__->meta->make_immutable(inline_constructor => 0);

1;