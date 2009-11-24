package Pyro::Server::ForwardProxy;
use Any::Moose;
use AnyEvent::AIO;
use AnyEvent::HTTP;
use IO::AIO;
use namespace::clean -except => qw(meta);

extends 'Pyro::Server';
with 'Pyro::PreforkServer';


sub process_request {
    my ($self, $request) = @_;

    $request->client->push_read( line => qr{(?<![^\012])\015?\012}, sub {
        my ($handle, $headers) = @_;

        if (! $request->parse_headers( $headers )) {
            $request->respond_client(599, undef, "Garbled response headers");
            $request->finalize();
            return;
        }

        if (my $ct_length = $request->header('Content-Length')) {
            $handle->push_read(chunk => $ct_length, sub {
                my ($handle, $data) = @_;
                $request->content( $data );
                $self->proxy_request( $request );
            } );
        } else {
            $self->proxy_request( $request );
        }
    });
    return;
}

sub proxy_request {
    my ($self, $request) = @_;

    $self->_schedule_request('www.endeworks.jp', sub {
        my ($guard) = @_;
        $request->finalize();
    });
    return; 

    http_request $request->method, $request->uri,
        %{$request->headers},
        want_body_handle => 1,
        sub {
            my ($handle, $headers) = @_;

            if (! $handle) {
                $request->respond_client(502);
                $request->finalize();
                return;
            }

            # if there's a Content-Length, read that much only, and go boom
            # (we don't use the built-in handling because we want to be
            # able to handle long polls)
            my $fh = $handle->fh;
            if (my $ct_length = $headers->{'content-length'}) {
                my $client_fh = $request->client->fh;
                aio_sendfile $client_fh, $fh, 0, $ct_length, sub {
                    if ($_[0] == $ct_length) {
                        $request->finalize();
                    }
                }
            } else {
                my $cb = sub {
                };
                $handle->on_eof( sub {
                    $request->finalize();
                });
                $handle->on_error( sub {
                    $request->respond_client(502);
                    $request->finalize();
                });
                $handle->on_timeout( sub {
                    $request->respond_client(502);
                    $request->finalize();
                });

                my $response = $request->response;
                while (my($k, $v) = each %$headers) {
                    $response->push_headers($k, $v);
                }
                $request->respond_header();
                $handle->push_read(sub {
                    my $data = shift;
                    $request->push_write( $data );
                    return;
                } );
            }
        }
    ;

}

1;
