package Pyro::Proxy::Client;
use Moose;
use AnyEvent::Socket;
use AnyEvent::Handle;
use Coro;
use HTTP::Date;
use HTTP::Request;
use HTTP::Response;
use Pyro::Handle;
use Pyro::Hook;
use Scalar::Util qw(weaken);
use URI;
use namespace::clean -except => qw(meta);

has handle => (
    is => 'ro',
    isa => 'GlobRef',
    required => 1
);

has hcache => (
    is => 'ro',
    isa => 'Pyro::Cache',
);

has request => (
    is => 'ro',
    isa => 'HTTP::Request',
    writer => 'set_request',
);

has response => (
    is => 'ro',
    isa => 'HTTP::Response',
    writer => 'set_response',
);

sub build_request {
    my ($self, $method, $url, $protocol, $headers) = @_;
    my $request = HTTP::Request->new($method, $url, [ %$headers ]);
    my $response = HTTP::Response->new(200, "OK");
    $response->request($request);
    $self->set_request($request);
    $self->set_response($response);
    return $request;
}

sub build_handle {
    my ($self, $context, $fh, @args) = @_;

    my $handle = Pyro::Handle->new(
        fh => $fh,
        @args,
    );
    return $handle;
}

sub start {
    my ($self, $context) = @_;

    my $server;
    my $client = $self->build_handle($context, $self->handle);
    {
        my $clear_guard = sub { delete $self->{guard} };
        $client->unshift_eof_callback( $clear_guard );
        $client->unshift_error_callback( $clear_guard );
    }

    my $respond = sub {
        $context->log->debug("REPLY: " . $self->response->code . "\n");
        $client->push_write( "HTTP/1.1 " . $self->response->as_string );
        $client->on_drain( sub {
            $context->log->debug( "FINALIZE - " . $self->request->uri . "\n" );
            $client->on_eof->get_callback_at(-1)->();
            $server->on_eof->get_callback_at(-1)->();
        } );
    };

    my $hcache = $self->hcache;

    # server handler.
    # this is simple, as it's just a HTTP request
    my $server_cb = sub {
        $self->modify_request();
        my $request = $self->request();
        my $host = $request->header('Host');
        my $port = 80;
        if (! $host) {
            my $uri = $request->uri;
            $host = $uri->host;
            $port = $uri->port;
        } elsif ($host =~ s/:(\d+)$//) {
            $port = $1;
        }
        my $respond_error = sub {
            $context->log->error( "FAIL " . $self->request->uri . "\n");
            $self->response->code(502);
            $respond->();
        };

        my $guard; $guard = tcp_connect $host, $port, sub {
            my $fh = shift;

            undef $guard;
            if (! $fh) {
                $respond_error->();
                return;
            }

            $server = $self->build_handle( $context, $fh,
                tmeout => 0.3,
            );
            $server->unshift_eof_callback( $respond_error );
            $server->unshift_timeout_callback( $respond_error );

            my $data = 
                sprintf("%s %s HTTP/1.1", $request->method, $request->uri) . "\n" .
                $request->headers->as_string() . "\n\n" .
                $request->content
            ;
            $server->push_write( $data );
            $server->push_read(line => qr{(?<![^\012])\015?\012}, sub {
                my ($server, $prologue) = @_;

                my ($protocol, $status, $message, $header_string, $headers) =
                    $self->_parse_response_prologue( $prologue );
                if ($hcache && $status eq 304) {
                    if ( my $cache = $hcache->get_content_cache_for( $request ) ) {
warn "here";
                        $context->log->debug( "CACHE: HIT on " . $request->uri . "\n");
                        $self->response($cache);
                        $self->response->request( $self->request );
                        $respond->();
                        return; # stop processing
                    }
                }

                my $response = $self->response;
                $response->code($status);
                $response->message($message);
                $response->headers->push_header(%$headers);
                my $post = sub {
                    if ($hcache && $hcache->set_lastmod_cache_if_applicable($response)) {
                        $hcache->set_content_cache_for( $self->response );
                    }
                };

                if (my $ct_length = $headers->{'content-length'}) {
                    $server->push_read(chunk => $ct_length, sub {
                        $self->response->content($_[1]);
                        $respond->();
                        AnyEvent->timer(after => 1,
                            cb => $post
                        );
                    });
                } else {
                    $respond->();
                    AnyEvent->timer(after => 1,
                        cb => $post
                    );
                }
            });
            $self->{guard}->{server} = $server;
        };
        $self->{guard}->{connect_guard} = $guard;
    };

    # client handler
    async {
    $client->push_read( line => qr{(?<![^\012])\015?\012},
        sub {
            my ($client, $prologue) = @_;

            my ($method, $url, $protocol, $header_string, $headers) = 
                $self->_parse_request_prologue( $prologue );

            $self->build_request( $method, $url, $protocol, $headers );
$context->log->debug( "REQUEST - " . $self->request->uri->path . "\n");
            if (my $ct_length = $headers->{'content-length'}) {
                $client->push_read(chunk => $ct_length, sub {
                    my ($client, $data) = @_;
                    $self->request->content( $data );
                    $server_cb->();
                });
            } else {
                $server_cb->(); 
            }
        }
    );
    $self->{guard}->{handle} = $client;
    $context->add_client( $self );
    }
}

my $url_re = qr{(?:(?:[^:/?#]+):)?(?://(?:[^/?#]*))?(?:[^?#]*)(?:\?(?:[^#]*))?(?:#(?:.*))?};

sub _parse_response_prologue {
    my ($self, $prologue) = @_;

    $prologue =~ y/\015//d;

    $prologue =~ s/^HTTP\/([0-9\.]+) \s+ ([0-9]{3}) (?: \s+ ([^012]*))?\012//ix;

    my ($protocol, $status, $message) = ($1, $2, $3);

    return ($protocol, $status, $message, $prologue,
        $self->_parse_headers( $prologue ) );
}

sub _parse_request_prologue {
    my ($self, $prologue) = @_;

    $prologue =~ y/\015//d;

    $prologue =~ s/^(\w+) +($url_re) +HTTP\/(.+)\012//;
    my ($method, $url, $protocol) = ($1, $2, $3);

    return ($method, $url, $protocol, $prologue,
        $self->_parse_headers( $prologue ));
}

sub _parse_headers {
    my ($self, $text) = @_;
    my %headers;

    while ($text =~ /\G
        ([^:\000-\037]+):
        [\011\040]*
        ( (?: [^\012]+ | \012 [\011\040] )* )
        \012
    /sgcx) {
      $headers{lc $1} .= ",$2"
    }

    return undef unless $text =~ /\G$/sgx;

    for (keys %headers) {
        substr $headers{$_}, 0, 1, '';
        # remove folding:
        $headers{$_} =~ s/\012([\011\040])/$1/sg;
    }

    return \%headers;
}

sub modify_request {
    my $self = shift;

    my $request = $self->request;

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

    if (my $hcache = $self->hcache) {
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
