package Pyro::Server::Web;
use Any::Moose;
use Any::Moose '::Util::TypeConstraints';
use AnyEvent;
use AnyEvent::AIO;
use Fcntl qw(O_RDONLY);
use HTTP::Date ();
use IO::AIO;
use Path::Class::File;
use POSIX qw(S_ISREG);
use namespace::clean -except => qw(meta);

extends 'Pyro::Server';
with 'Pyro::PreforkServer';

has client => (
    is => 'ro',
    lazy_build => 1,
);

subtype 'Pyro::Path'
    => as 'Path::Class::Dir'
;
coerce 'Pyro::Path'
    => from 'Str'
    => via { Path::Class::Dir->new($_) }
;
has document_root => (
    is => 'ro',
    isa => 'Pyro::Path',
    coerce => 1,
    required => 1,
);

sub serve_request {
    my ($self, $request) = @_;

    my $docroot = $self->document_root or
        return $request->respond_client(500, undef, "Docroot unconfigured");

    my $file = $docroot->file($request->uri);

    aio_stat $file->stringify, sub {
        my ($mode, $size, $mtime) = (stat(_))[2, 7,9];
        if (! -e _ || ! S_ISREG($mode) ) {
            $request->respond_client(404);
            return;
        }

        # ok, the file exists, 
        my $lastmod = HTTP::Date::time2str($mtime);
        my $ims     = $request->header('If-Modified-Since') || '';

        # IE sends a request header like "If-Modified-Since: <DATE>; 
        # length=<length>" so we have to remove the length bit before 
        # comparing it with our date. then we save the length to compare later.

        my $ims_len;
        if ($ims && $ims =~ s/;\s*length=(\d+)//) {
            $ims_len = $1;
        }

        my $not_modified = $ims eq $lastmod && -f _ && (! defined $ims_len || $ims_len == $size);

        if ($not_modified) {
            $request->new_response(304);
        }

        $request->response->header( 'Date', HTTP::Date::time2str() );
        $request->response->header( 'Last-Modified', $lastmod );
        $request->respond_headers;
        if ($request->method eq 'HEAD' || $not_modified ) { # || $not_satisfiable) {
            return;
        }

    
        aio_open $file->stringify, O_RDONLY, 0, sub {
            my $fh = shift;

            if (! $fh) {
                $request->respond_client(500, undef, "open resource failed: $!");
                return;
            }

            if (! $request->client->fh) {
                $request->finalize();
                return;
            }

            aio_sendfile $request->client->fh, $fh, 0, $size, sub {
                $request->finalize();
            };
        };
    };
}

sub process_request {
    my ($self, $request) = @_;

    my $uri = $request->uri;
    if ($uri =~ /\.\./ || $uri !~ /^\//) {
        $request->respond_client(403, undef, "Invalid URL");
        $request->finalize();
        return;
    }

    # At this point, we only have the request line, so go and start 
    # reading headers

    my $method = $request->method;
    if ( $method eq 'GET' || $method eq 'HEAD' || $method eq 'PUT' || $method eq 'DELETE' ) {
        # read the rest of the headers
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
                    $self->serve_request( $request );
                } );
            } else {
                $self->serve_request( $request );
            }
        });
        return;
    }
    $request->respond_client(400, undef, "bad request");
}

sub _build_on_accept {
    my $self = shift;
    return sub {
        my ($fh, $context, $cv) = @_;
        $self->process_connection( $fh, $context, $cv );
    }
}

sub _build_on_stop {
    my $self = shift;
    return sub { $self->context->stop };
}

__PACKAGE__->meta->make_immutable();

1;