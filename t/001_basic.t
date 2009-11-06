use strict;
use lib "t/lib";
use Pyro::Test;
use Test::More tests => 6;

test_proxy(
    client => sub {
        my %args = @_;

        my $uri_base = URI->new( "http://127.0.0.1:$args{server_port}" );
        my @uris = (
            $uri_base->clone,
            do { my $u = $uri_base->clone; $u->path('/foo'); $u }
        );

        my $cv = AnyEvent->condvar;
        my $count = scalar @uris;
        foreach my $uri (@uris) {
            http_get
                $uri,
                proxy => [ '127.0.0.1', $args{proxy_port}, 'http' ],
                sub {
                    my ($data, $hdrs) = @_;
                    if (! is( $hdrs->{Status}, 200 ) ) {
                        diag( $hdrs->{Reason} );
                    }
                    is( $hdrs->{"x-pyro-test"}, "foobar" );
                    is( $data, "OK " . ($uri->path || '/'));
                    $count--;
                    $cv->send if $count == 0;
                }
            ;
        }
        $cv->recv;
    },
    server => sub {
        my $env = shift;
        my $req = Plack::Request->new($env);
        my $res = $req->new_response(200, [
            "Content-Type" => 'text/html; charset=utf-8',
            "X-Pyro-Test"  => "foobar",
        ], "OK $env->{PATH_INFO}");
        return $res->finalize;
    },
);

