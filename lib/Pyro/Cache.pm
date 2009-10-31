package Pyro::Cache;
use Moose;
use Moose::Util::TypeConstraints;
use HTTP::Date;
use namespace::clean -except => qw(meta);

class_type 'Cache::Memcached';
class_type 'Cache::Memcached::Fast';
class_type 'Cache::Memcached::libmemcached';
has cache => (
    is => 'ro',
    isa => 'Cache::Memcached | Cache::Memcached::Fast | Cache::Memcached::libmemcached',
    lazy_build => 1,
);

sub _build_cache {
    my $cache_class = 'Cache::Memcached::Fast';
    if (! Class::MOP::is_class_loaded($cache_class)) {
        Class::MOP::load_class($cache_class);
    }
    my $cache = $cache_class->new( {
        servers => [ '127.0.0.1:11211' ],
        compress_threshold => 10_000,
    } );

    if ($cache_class->isa('Cache::Memcached::libmemcached')) {
        $cache->set_binary_protocol(1);
    }
    return $cache;
}

sub set_lastmod_cache_if_applicable {
    my ($self, $response) = @_;
    if (my $last_modified = $response->header('Last-Modified')) {
        my $key = $response->request->uri . '.lastmod';
        my $time = HTTP::Date::str2time($last_modified);
        my $v = $self->cache->get($key);
        if (! $v || $time >= $v) {
            $self->cache->set($key => $time);
        }
        return 1;
    }
    return;
}

sub set_content_cache_for {
    my ($self, $response) = @_;
    $self->cache->set(
        $response->request->uri . '.request' => $response
    );
}

sub get_content_cache_for {
    my ($self, $request) = @_;
    $self->cache->get( $request->uri . '.request' );
}

sub get_last_modified_cache_for {
    my ($self, $request) = @_;
    $self->cache->get( $request->uri . '.lastmod' );
}


__PACKAGE__->meta->make_immutable();

1;
