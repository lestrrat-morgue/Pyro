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
    $self->log->debug("BACKEND: queued " . $self->original_uri);
    $self->backend->push_queue( $self );
}

sub respond_to_client {
    my ($self, $data, $headers) = @_;

    my $response = $self->_response;
    $response->content($data);
    $response->code( delete $headers->{Status} );
    $response->message(delete $headers->{Reason} );
    while (my ($key, $value) = each %$headers ) {
        $response->push_header($key, $value);
    }

    $self->client->push_write(
        "HTTP/1.1 " . $response->code . "\n" .
        $response->as_string
    );
    $self->client->on_drain( sub { 
        close($self->client->fh);
    });
}
    

__PACKAGE__->meta->make_immutable();

1;

