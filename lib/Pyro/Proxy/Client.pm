package Pyro::Proxy::Client;
use Moose;
use AnyEvent::Socket;
use Coro;
use HTTP::Date;
use HTTP::Response;
use Pyro::Handle;
use Pyro::Hook;
use Pyro::Request;
use Scalar::Util qw(weaken);
use URI;
use namespace::clean -except => qw(meta);

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
    my ($self, $client, $method, $url, $protocol, $headers, $hcache, $log) = @_;

    my %args = (
        client   => $client,
        method   => $method,
        uri      => $url,
        headers  => $headers,
        log      => $log,
    );
    if ($hcache) {
        $args{hcache} = $hcache;
    }

    my $request = Pyro::Request->new(%args);
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

# Process a new connection. At this point we still don't know if we're going
# to get a valid HTTP request. Our goal is to read enough data to create
# a request, and let it be handled by the backend
sub process_connection {
    my ($self, $fh, $context) = @_;

    $context->log->debug("New connection!\n");
    my $client = Pyro::Handle->new( fh => $fh );

    $client->push_read( line => qr{(?<![^\012])\015?\012},
        sub {
            my ($client, $prologue) = @_;

            my ($method, $url, $protocol, $header_string, $headers) = 
                $self->_parse_request_prologue( $prologue );

            my $request = $self->build_request(
                $client,
                $method,
                $url,
                $protocol,
                $headers,
                $context->hcache,
                $context->log,
            );
$request->log->debug( "REQUEST - " . $request->original_uri . "\n");
            if (my $ct_length = $headers->{'content-length'}) {
                $client->push_read(chunk => $ct_length, sub {
                    my ($client, $data) = @_;
                    $request->content( $data );
                    $request->push_to_backend();
                });
            } else {
                $request->push_to_backend();
            }
        }
    );
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

__PACKAGE__->meta->make_immutable();

1;
