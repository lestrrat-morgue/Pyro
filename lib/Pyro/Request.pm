package Pyro::Request;
use Any::Moose;
use HTTP::Headers;
use HTTP::Response;
use HTTP::Status;
use namespace::clean -except => qw(meta);

has client => (
    is => 'rw',
    isa => 'AnyEvent::Handle',
);

has content => (
    is => 'rw',
);

has cv => (
    is => 'rw',
    isa => 'Object',
    required => 1,
);

has headers => (
    is => 'rw',
    isa => 'HTTP::Headers',
    handles => {
        header => 'header',
    }
);

has method => (
    is => 'rw',
    isa => 'Str',
);

has protocol => (
    is => 'rw',
    isa => 'Str',
    default => '1.1',
);

has tls_ctx => (
    is => 'ro',
    isa => 'Str',
    default => 'low',
);

has uri => (
    is => 'rw',
    isa => 'Str',
);

has response => (
    is => 'rw',
    isa => 'HTTP::Response',
    lazy_build => 1,
);

around uri => sub {
    my $next = shift;
    my $self = shift;
    if (@_) {
        my $uri = shift;
        $uri =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
        return $next->($self, $uri);
    } else {
        return $next->($self);
    }
};

sub _build_response {
    my $self = shift;
    my $res = HTTP::Response->new(200, status_message(200),
        [ 'Server' => "Pyro/$Pyro::VERSION" ] ); 
    $res->protocol( 'HTTP/' . $self->protocol );
    return $res;
}

sub new_response {
    my ($self, @args) = @_;

    my $res = HTTP::Response->new(@args);
#    $res->header( 'Server' => "Pyro/$Pyro::VERSION" ); 
    $res->protocol( 'HTTP/' . $self->protocol );
    $self->response( $res );
    return $res;
}

sub respond_headers {
    my $self = shift;

    my $response = $self->response;
    my $headers = $response->headers;

    $self->client->push_write(
        join(' ', $response->code, $response->message, $response->protocol) . "\012" .
        $headers->as_string . "\012"
    );
}

sub respond_body {
    my $self = shift;

    $self->client->push_write($self->response->content);
}

sub respond_client {
    my $self = shift;

    if (@_) {
        my ($code, $headers, $body) = @_;
        my $res = $self->new_response(
            $code,
            status_message($code),
            [ ref $headers eq 'ARRAY' ? @$headers : () ]
        );
        if (defined $body) {
            $res->content($body);
        }
    }

    $self->client->push_write( $self->response->as_string );
}

sub parse_headers {
    my ($self, $headers) = @_;

    my %parsed;

    # adapted from AE::HTTP
    
    # weed out any \015, as they show up in the weirdest of places.
    $headers =~ y/\015//d; 

    $parsed{lc $1} .= ",$2"
        while($headers =~ /\G
            ([^:\000-\037]*):
            [\011\040]*
            ((?: [^\012]+ | \012[\011\040] )*)
            \012
        /gxc)
    ;

    if ( $headers !~ /\G$/ ) {
        return;
    }

    substr $_, 0, 1, "" for values %parsed;

    $self->headers( HTTP::Headers->new( %parsed ) );
    return 1;
}

sub finalize {
    my $self = shift;
    $self->cv->end;
}

sub DEMOLISH {
    warn "Pyro::Request::DEMOLISH";
}

__PACKAGE__->meta->make_immutable();

1;
