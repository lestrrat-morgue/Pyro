package Pyro::Proxy::Backend;
use Moose;
use AnyEvent::HTTP qw(http_request);
use namespace::clean -except => qw(meta);

has queue => (
    traits => ['Array'],
    is => 'ro',
    isa => 'ArrayRef',
    lazy_build => 1,
    handles => {
        push_queue => 'push',
        pop_queue  => 'pop',
    }
);

my %INSTANCES;

sub _build_queue { [] }

# one connection per host:port, you can push requests
sub instance {
    my ($class, $host, $port) = @_;
    # XXX FIXME - make it more efficient 

    return $INSTANCES{ "$host:$port" } ||= $class->new( host => $host, port => $port );
}

# before pushing a request, make sure it's kosher.
before push_queue => sub {
    # XXX - TODO
};

# once you push a request, start draining
after push_queue => sub {
    my $self = shift;
    $self->drain_queue();
};

sub drain_queue {
    my $self = shift;
    
    if (my $request = $self->pop_queue) {
        $self->process_request($request);
    }
}

sub process_request {
    my ($self, $request) = @_;

    $self->modify_request( $request );
    $self->send_request( $request );
}

sub send_request {
    my ($self, $request) = @_;

    # basic strategy: 
    #   maybe_cached = has IMS or Etag header
    #   if ( maybe_cached ) {
    #      make a HEAD request with same parameters.
    #      if cache condition matches, and there's a cache,
    #      return the cache 
    #   }
    #
    #   got here, so we have to make a fresh request nonetheless
    #   do a regular request

    # this flag is set when there's no chance the request can be cached
    my $no_cache = 
        $request->method !~ /^(?:GET)$/ ||
        ($request->header('Pragma') || '') !~ /\bno-cache\b/ ||
        ($request->header('Cache-Control') || '') !~ /\bno-cache\b/
    ;

    if ($no_cache) {
        $self->send_request_no_probe( $request );
    }

warn "SENDING request";
    my $guard; $guard = http_request 'HEAD' => $request->original_uri,
        headers => $request->headers,
        timeout => 0.5,
        on_header => sub {
            my $headers = shift;
            if ( $headers->{Status} eq '304' ) {
                confess "Unimplemented";
            }

            # if we got here, we couldn't cache. do the real transaction
            $self->send_request_no_probe( $request );
        },
    ;
}

sub send_request_no_probe {
    my ($self, $request) = @_;

    http_request
        $request->method => $request->original_uri,
        headers => $request->headers,
        sub {
            $request->respond_to_client( @_ );
            $self->drain_queue();
        }
    ;
}

sub modify_request {
    my ($self, $request) = @_;

    # Normalize the URI (hey, you DID send us a complete URI, right?)
    # After this point, we /guarantee/ that the request contains a valid Host
    # header, and the request URL doesn't contain anything before the path 
    my $uri = $request->uri;
    if (my $code = $uri->can('host')) {
        if (my $host = $code->($uri)) {
            if ( ! $request->header('Host')) { # XXX is this right?
                my $port = $uri->port;
                $request->header(Host => "$host:$port");
            }

            $uri->scheme(undef);
            $uri->host(undef);
            $uri->port(undef);
            $uri->authority(undef); # XXX need to fix this later
        }
    }
    if (! $uri->path) {
        $uri->path('/');
    }

    $request->_request->remove_header('Keep-Alive');

    if (! $request->header('If-Modified-Since') && (my $hcache = $request->hcache) ) {
        # check if we have a Last-Modified stored
        my $last_modified = $hcache->get_last_modified_cache_for( $request );
        if ($last_modified) {
            $request->header('If-Modified-Since',
                HTTP::Date::time2str( $last_modified ) );
        }
    }
}

__PACKAGE__->meta->make_immutable();

1;

__END__
