use strict;
use lib "t/lib";
use Pyro;
use Plack;
use Plack::Loader;
use Plack::Request;
use Pyro::Test qw(test_proxy);
use LWP::UserAgent;
use Test::More tests => 2;

Pyro::Test::test_proxy(
    client => sub {
        my %args = @_;

        my $ua = LWP::UserAgent->new();
        my $res = $ua->get( "http://127.0.0.1:$args{proxy_port}");
        is( $res->code, 200 );
        is( $res->content, "OK" );
    },
    server => sub {
        my $port = shift;
        my $plack = Plack::Loader->load("Standalone", port => $port);
        $plack->run( sub {
            my $env = shift;
            my $req = Plack::Request->new($env);
            my $res = $req->new_response(200, [ "Content-Type" => 'text/html; charset=utf-8' ], "OK");
            return $res->finalize;
        } );
    },
    proxy => sub {
        my $port = shift;
        Pyro->new(port => $port)->start;
    }
);

