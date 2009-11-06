package Pyro::Log;
use Moose;
use namespace::clean -except => qw(meta);

has log_map => (
    traits => ['Hash'],
    is => 'ro',
    isa => 'HashRef',
    lazy_build => 1,
    handles => {
        add_logger => 'set',
        get_loggers => 'get',
    }
);

sub _build_log_map {
    my $stderr = AnyEvent::Handle->new(
        fh => \*STDERR,
        on_eof => sub { },
        on_error => sub { },
    );

    return {
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
                $logger->push_write("[$level]: @_");
            }
        }
    });
}

__PACKAGE__->meta->make_immutable();

1;

