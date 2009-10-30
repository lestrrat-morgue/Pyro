package Pyro::Proxy::Client;
use Moose;
use AnyEvent::Socket;
use AnyEvent::Handle;
use HTTP::Date;
use HTTP::Request;
use HTTP::Response;
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

sub start {
    my ($self, $context) = @_;

    weaken($self);
    my $hdl = AnyEvent::Handle->new(
        fh => $self->handle,
    );

    my $make_finalizer = sub {
        my $victim = shift;
        return sub {
            if ($victim) { # paranoid
                close($victim->fh) if $victim->fh;
                $victim->destroy();
            }
        }
    };
    my $main_finalize = $make_finalizer->( $hdl );
    my $client_finalize = sub {
        delete $self->{guard}; # delete'em all
        $main_finalize->();
    };

    $hdl->on_eof( $client_finalize ); # close 

    my $hcache = $self->hcache;

    # server handler.
    # this is simple, as it's just a HTTP request
    my $server_cb = sub {
        my $request = shift;

        $self->modify_request( $request );
        my $host = $request->header('Host');
        my $port = 80;
        if (! $host) {
            my $uri = $request->uri;
            $host = $uri->host;
            $port = $uri->port;
        } elsif ($host =~ s/:(\d+)$//) {
            $port = $1;
        }
        my $guard; $guard = tcp_connect $host, $port, sub {
            my $fh = shift;

            undef $guard;
            if (! $fh) {
                warn "failed to connect to $host:$port";
                $client_finalize->();
                return;
            }

            my $server; $server = AnyEvent::Handle->new(
                fh => $fh,
                tmeout => 0.3,
            );
            my $server_finalize = $make_finalizer->($server);
            $server->on_eof( $server_finalize );
            $server->on_timeout( sub {
                $hdl->push_write(
                    "HTTP/1.1 502 Server Timeout\nServer: Pyro\n\n"
                );
                $hdl->on_drain( sub {
                    $client_finalize->();
                    $server_finalize->();
                } );
            } );

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
                        $server_finalize->();
                        $hdl->push_write( $cache );
                        $hdl->on_drain( sub {
                            $client_finalize->();
                        } );
                        return; # stop processing
                    }
                }

                my $response = HTTP::Response->new($status, $message, [ %$headers ]);
                $response->request($request);
                my $post = sub {
                    if ($hcache && $hcache->set_lastmod_cache_if_applicable($response)) {
                        $hcache->set_content_cache_for( $response );
                    }
                };

                if (my $ct_length = $headers->{'content-length'}) {
                    $server->push_read(chunk => $ct_length, sub {
                        $response->content($_[1]);
                        $hdl->push_write(
                            "HTTP/$protocol $status $message\n" .
                            "$header_string\n" .
                            $_[1]
                        );
                        $hdl->on_drain( sub {
                            $client_finalize->();
                            $server_finalize->();
                            $post->();
                        });
                    });
                } else {
                    $hdl->push_write(
                        "HTTP/$protocol $status $message\n" .
                        "$header_string\n"
                    );
                    $hdl->on_drain( sub {
                        $client_finalize->();
                        $server_finalize->();
                        $post->();
                    } );
                }
            });
            $self->{guard}->{server} = $server;
        };
        $self->{guard}->{connect_guard} = $guard;
    };

    # client handler
    $hdl->push_read( line => qr{(?<![^\012])\015?\012},
        sub {
            my ($hdl, $prologue) = @_;

            my ($method, $url, $protocol, $header_string, $headers) = 
                $self->_parse_request_prologue( $prologue );

            my $r = HTTP::Request->new($method, $url);
            $hdl->{request} = $r;

            if (my $ct_length = $headers->{'content-length'}) {
                $hdl->push_read(chunk => $ct_length, sub {
                    my ($hdl, $data) = @_;
                    $hdl->{request}->content( $data );
                    $server_cb->($hdl->{request});
                });
            } else {
                $server_cb->($hdl->{request}); 
            }
        }
    );
    $self->{guard}->{handle} = $hdl;
    $context->add_client( $self );
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
