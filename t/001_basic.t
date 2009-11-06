use strict;
use lib "t/lib";
use Pyro::Test;
use Test::More tests => 3;

test_proxy(
    client => sub {
        my %args = @_;

        my $cv = AnyEvent->condvar;
        http_get
            "http://127.0.0.1:$args{server_port}",
            proxy => [ '127.0.0.1', $args{proxy_port}, 'http' ],
            sub {
                my ($data, $hdrs) = @_;
                is( $hdrs->{Status}, 200 );
                is( $hdrs->{"x-pyro-test"}, "foobar" );
                is( $data, "OK" );
                $cv->send;
            }
        ;
        $cv->recv;
    },
    server => sub {
        my $env = shift;
        my $req = Plack::Request->new($env);
        my $res = $req->new_response(200, [
            "Content-Type" => 'text/html; charset=utf-8',
            "X-Pyro-Test"  => "foobar",
        ], "OK");
        return $res->finalize;
    },
);

