package Pyro::Server;
use Any::Moose;
use AnyEvent;
use AnyEvent::Handle;
use Pyro::Request;
use namespace::clean -except => qw(meta);

has context => (is => 'rw', weak_ref => 1);

has request_timeout => (
    is => 'ro',
    isa => 'Int',
    default => 30
);

sub start {
    my ($self, $context) = @_;
    $self->context($context);
}

sub process_connection {
    my ($self, $fh, $context, $server_cv,) = @_;

    my $client = AnyEvent::Handle->new( fh => $fh );
    $self->wait_request( $client, $context, $server_cv );
}

sub wait_request {
    my ($self, $client, $context, $server_cv) = @_;

    my $request = Pyro::Request->new(cv => $server_cv);

    # wait for the first line of an HTTP request
    my $timer = AE::timer $self->request_timeout, 0, sub {
        $self->disconnect();
    };

    $client->push_read(line => sub {
        my ($handle, $line) = @_;
        undef $timer;

        # are we done for? don't contintue
        return unless defined $self;

        if ($line =~ /(\S+) \s+ (\S+) \s+ HTTP\/(\d+\.\d+)/xs) {
            my ($method, $uri, $protocol) = ($1, $2, $3);

            $request->method  ( $method );
            $request->uri     ( $uri ); 
            $request->protocol( $protocol );
            $request->client  ( $handle );
            $self->process_request( $request );
        } elsif ($line eq '') {
            $self->wait_request( $client );
        } else {
            die "fuck";
        }
    });
}

__PACKAGE__->meta->make_immutable();

1;
