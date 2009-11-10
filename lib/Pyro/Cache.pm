package Pyro::Cache;
use Moose;
use Digest::MD5 qw(md5_hex);
use Moose::Util::TypeConstraints;
use HTTP::Date;
use namespace::clean -except => qw(meta);

class_type 'Cache::Memcached';
class_type 'Cache::Memcached::Fast';
class_type 'Cache::Memcached::libmemcached';

has cache => (
    is => 'ro',
    isa => 'Maybe[ Cache::Memcached | Cache::Memcached::Fast | Cache::Memcached::libmemcached ]',
    lazy_build => 1,
);

has servers => (
    is => 'ro',
    isa => 'ArrayRef',
    predicate => 'has_servers',
);

sub _build_cache {
    my $self = shift;
    my $cache;

    if ( $self->has_servers ) {
        my $cache_class = 'Cache::Memcached::Fast';
        if (! Class::MOP::is_class_loaded($cache_class)) {
            Class::MOP::load_class($cache_class);
        }
        $cache = $cache_class->new( {
            servers => $self->servers,
            compress_threshold => 10_000,
        } );

        if ($cache_class->isa('Cache::Memcached::libmemcached')) {
            $cache->set_binary_protocol(1);
        }
    }
    return $cache;
}

sub get {
    my $self = shift;
    if (my $cache = $self->cache) {
        return $cache->get(@_);
    }
    return;
}

sub set {
    my $self = shift;
    if ((my $cache = $self->cache) && defined $_[0] && defined $_[1]) {
        return $cache->set(@_);
    }
    return;
}

sub set_lastmod_cache_if_applicable {
    my ($self, $response) = @_;
    if (my $last_modified = $response->header('Last-Modified')) {
        my $key = $response->request->original_uri . '.lastmod';
        my $time = HTTP::Date::str2time($last_modified);
        my $v = $self->get($key);
        if (! $v || $time >= $v) {
            $self->cache->set($key => $time);
        }
        return 1;
    }
    return;
}

sub set_content_cache_for {
    my ($self, $response) = @_;
    $self->set(
        $response->request->original_uri . '.request' => $response
    );
}

sub get_content_cache_for {
    my ($self, $request) = @_;
    $self->get( $request->original_uri . '.request' );
}

sub get_last_modified_cache_for {
    my ($self, $request) = @_;
    $self->get( md5_hex( $request->original_uri . '.lastmod' ) );
}


__PACKAGE__->meta->make_immutable();

1;
