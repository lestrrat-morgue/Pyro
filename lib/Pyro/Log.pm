package Pyro::Log;
use Any::Moose;
use namespace::clean -except => qw(meta);

has log_map => (
    is => 'ro',
    isa => 'HashRef',
    lazy_build => 1,
);

sub add_logger { shift->log_map->{$_[0]} = $_[1] }
sub get_loggers { shift->log_map->{$_[0]} }

sub _build_log_map {
    my $stderr = AnyEvent::Handle->new(
        fh => \*STDERR,
        on_eof => sub { },
        on_error => sub { },
    );
    my $stdout = AnyEvent::Handle->new(
        fh => \*STDOUT,
        on_eof => sub { },
        on_error => sub { },
    );

    return {
        info  => [ $stdout ],
        error => [ $stderr ],
        debug => [ $stderr ],
    }
}

foreach my $level qw(debug error info) {
    __PACKAGE__->meta->add_method($level => sub {
        my $self = shift;
        my $loggers = $self->get_loggers($level);
        if ($loggers) {
            foreach my $logger (@$loggers) {
                $logger->push_write("[$level ($$)]: @_");
            }
        }
    });
}

__PACKAGE__->meta->make_immutable();

1;

