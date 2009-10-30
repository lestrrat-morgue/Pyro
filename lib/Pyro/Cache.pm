package Pyro::Cache;
use Moose;
use Cache::Memcached::libmemcached;
use HTTP::Date;
use namespace::clean -except => qw(meta);

has cache => (
    is => 'ro',
    isa => 'Cache::Memcached::libmemcached',
    lazy_build => 1,
);

sub _build_cache {
    my $cache = Cache::Memcached::libmemcached->new( {
        servers => [ '127.0.0.1:11211' ],
        compress_threshold => 10_000,
    } );
    $cache->set_binary_protocol(1);
    return $cache;
}

sub set_lastmod_cache_if_applicable {
    my ($self, $response) = @_;
    if (my $last_modified = $response->header('Last-Modified')) {
        $self->cache->set(
            $response->request->uri . '.lastmod' => HTTP::Date::str2time($last_modified)
        );
        return 1;
    }
    return;
}

sub set_content_cache_for {
    my ($self, $response) = @_;
    if (my $content = $response->content) {
        $self->cache->set(
            $response->request->uri . '.content' => $content
        );
    }
}

sub get_content_cache_for {
    my ($self, $request) = @_;
    $self->cache->get( $request->uri . '.content' );
}

sub get_last_modified_cache_for {
    my ($self, $request) = @_;

    $self->cache->get( $request->uri . '.lastmod' );
}


__PACKAGE__->meta->make_immutable();

1;
