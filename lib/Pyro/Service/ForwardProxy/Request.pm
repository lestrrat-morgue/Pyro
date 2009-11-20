package Pyro::Service::ForwardProxy::Request;
use Any::Moose;
use Digest::MD5 qw(md5_hex);
use HTTP::Request;
use HTTP::Response;
use Pyro::Service::ForwardProxy::Backend;
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
    isa => 'Pyro::Service::ForwardProxy::Backend',
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
    lazy_build => 1,
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

sub _build_hcache { Pyro::Cache->new() }
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
    Pyro::Service::ForwardProxy::Backend->instance( $original_uri->host, $original_uri->port );
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
    ${$response->content_ref} .= $data;
    $client->push_write( $data );
}

sub finalize_response {
    my $self = shift;
    my $client = $self->client;

    $client->on_drain( sub { 
        close($self->client->fh);
        $self->log->debug("RESPOND: " . $self->original_uri . "\n");

        # if it's cacheable, send it to the cache
        my $no_cache = 
            $self->method !~ /^(?:GET)$/i ||
            ($self->header('Pragma') || '') =~ /\bno-cache\b/i ||
            ($self->header('Cache-Control') || '') =~ /\bno-cache\b/i
        ;

        # if I have a last modified or an etag, I should cache it
        if ( ! $no_cache ) {
            my $response = $self->_response;
            if ($response->header('last-modified') || $response->header('etag')) {
                $self->send_to_cache();
            }
        }
    });
}
    
sub respond_from_cache {
    my ($self, $headers) = @_;

    my $hcache = $self->hcache;
    my $content = $hcache->get( md5_hex( $self->original_uri . '.content' ) );
    if ($content) {
        $self->log->debug("CACHE: GET " . $self->original_uri . " (HIT)\n");
        $self->respond_headers( $headers );
        $self->respond_data( $content );
        $self->finalize_response();
        return 1;
    }
    $self->log->debug("CACHE: GET " . $self->original_uri . " (MISS)\n");
    return;
}

sub send_to_cache {
    my $self = shift;

    $self->log->debug("CACHE: SET " . $self->original_uri . "\n");

    my $response =  $self->_response;

    # We don't really care if the request was properly cached or not
    my $hcache = $self->hcache;
    $hcache->set( md5_hex( $self->original_uri . '.content' ), $response->content);
    $hcache->set( md5_hex( $self->original_uri . '.lastmod' ), 
        HTTP::Date::str2time($response->header('Last-Modified')));
}

__PACKAGE__->meta->make_immutable();

1;
    

