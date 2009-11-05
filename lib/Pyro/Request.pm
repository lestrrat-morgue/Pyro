package Pyro::Request;
use Moose;
use HTTP::Request;
use HTTP::Response;
use Pyro::Proxy::Backend;
use namespace::clean -except => qw(meta);

has _request => (
    is => 'ro',
    lazy_build => 1,
    handles => {
        content => 'content',
        header  => 'header',
        headers => 'headers',
        method  => 'method',
        uri     => 'uri',
    }
);

has _response => (
    is => 'ro',
    lazy_build => 1,
);

has backend => (
    is => 'ro',
    isa => 'Pyro::Proxy::Backend',
    lazy_build => 1,
);

has client => (
    is => 'ro',
    isa => 'Pyro::Handle',
    required => 1,
);

has log => (
    is => 'ro',
    isa => 'Pyro::Log',
    required => 1,
);

has hcache => (
    is => 'ro',
    isa => 'Pyro::Cache',
    required => 1,
);

sub BUILD {
    my ($self, $args) = @_;

    my $request = $self->_request;
    my $headers = delete $args->{headers};
    while (my ($key, $value) = each %$args) {
        next if $self->meta->has_attribute($key);
        $request->$key($value);
    }
    while (my ($key, $value) = each %$headers) {
        $request->push_header( $key, $value );
    }
    return $self;
}

sub _build__request { HTTP::Request->new() }
sub _build__response {
    my $self = shift;
    my $res = HTTP::Response->new();
    $res->request($self->_request);
    return $res;
}

sub _build_backend {
    my $self = shift;
    my $original_uri = $self->original_uri;
    Pyro::Proxy::Backend->instance( $original_uri->host, $original_uri->port );
}

# the original uri requires that we have a "complete" url
sub original_uri {
    my $self = shift;

    my $uri = $self->uri->clone;
    # better be https? or otherwise...
    my $scheme = $uri->scheme;
    if (! $scheme ) {
        # relative path, probably?
        my $host = $self->header('Host');
        my $port = 80;
        if ( $host =~ s/:(\d+)$// ) {
            $port = $1;
        }
        if ( $port eq 443 ) {
            $uri->scheme('https');
        } else {
            $uri->scheme('http');
        }
        $uri->host( $host );
        $uri->port( $port );
    }
    return $uri->canonical;
}

sub push_to_backend {
    my $self = shift;
    $self->log->debug("BACKEND: queued " . $self->original_uri . "\n");
    $self->backend->push_queue( $self );
}

sub respond_headers {
    my ($self, $hdrs) = @_;

    my $code     = delete $hdrs->{Status};
    my $message  = delete $hdrs->{Reason};
    my $protocol = delete $hdrs->{HTTPVersion};
    my $response = $self->_response;
    my $headers  = $response->headers;
    my $client  = $self->client;

    $response->code( $code );
    $response->message( $message );
    while ( my( $key, $value ) = each %$hdrs ) {
        $headers->push_header( $key, $value );
    }

    $client->push_write( "HTTP/$protocol $code $message\n" );
    $client->push_write( $headers->as_string . "\n" );
}

sub respond_data {
    my ($self, $data) = @_;

    my $response = $self->_response;
    my $client = $self->client;
    $response->content($data);
    $client->push_write( $data );
}

sub finalize_response {
    my $self = shift;
    my $client = $self->client;
    $client->on_drain( sub { 
        close($self->client->fh);
        $self->log->debug("RESPOND: " . $self->original_uri . "\n");
    });
}
    

__PACKAGE__->meta->make_immutable();

1;
    
