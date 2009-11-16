package Pyro::PreforkServer;
use Moose::Role;
use Socket qw(AF_INET AF_UNIX SOCK_STREAM SOL_SOCKET SO_REUSEADDR);
use AnyEvent;
use AnyEvent::Handle;
use AnyEvent::Socket qw(address_family parse_address format_address);
use AnyEvent::Util qw(AF_INET6 fh_nonblocking);
use POSIX qw(WNOHANG);
use namespace::clean -except => qw(meta);

has concurrency => (
    is => 'ro',
    isa => 'Int',
    default => 10
);

has host => (
    is => 'ro',
);

has listen_queue => (
    is => 'ro',
    isa => 'Int',
    default => 128,
);

has port => (
    is => 'ro',
    default => 8888
);

has on_accept => (
    is => 'ro',
    isa => 'CodeRef',
    lazy_build => 1,
    required => 1,
);

has on_stop => (
    is => 'ro',
    isa => 'CodeRef',
    lazy_build => 1,
    required => 1,
);

sub _build_on_accept {}

sub start {
    my ($self, $context) = @_;

    my $host = $self->host;
    my $service = $self->port;

    # Most of below are taken from AnyEvent::Socket, with some modifications
    if (! defined $host) {
        $host = 
            $AnyEvent::PROTOCOL{ipv4} < $AnyEvent::PROTOCOL{ipv6} && 
            AF_INET6 ? "::" : "0"
    }
    my $ipn = parse_address $host
        or Carp::croak __PACKAGE__ . ": cannot parse '$host' as host address";

    my $af = address_family $ipn;

    # win32 perl is too stupid to get this right :/
    Carp::croak "tcp_server/socket: address family not supported"
        if AnyEvent::WIN32 && $af == AF_UNIX;

    my $socket;
    socket $socket, $af, SOCK_STREAM, 0
        or Carp::croak "tcp_server/socket: $!";

    if ($af == AF_INET || $af == AF_INET6) {
        setsockopt $socket, SOL_SOCKET, SO_REUSEADDR, 1
            or Carp::croak "tcp_server/so_reuseaddr: $!"
            unless AnyEvent::WIN32; # work around windows bug

        unless ($service =~ /^\d*$/) {
                $service = (getservbyname $service, "tcp")[2]
                     or Carp::croak "$service: service unknown"
        }
    } elsif ($af == AF_UNIX) {
        unlink $service;
    }

    bind $socket, AnyEvent::Socket::pack_sockaddr($service, $ipn)
        or Carp::croak "bind: $!";

    fh_nonblocking($socket, 1);
    listen $socket, $self->listen_queue
        or Carp::croak "listen: $!";

    my %children;
    local %SIG;
    foreach my $sig qw(INT HUP QUIT TERM) {
        $SIG{$sig} = sub {
            foreach my $pid (keys %children) {
                print "Received $sig: Killing $pid\n";
                kill TERM => $pid;
            }
        }
    };

    for(1..$self->concurrency) {
        my $pid = fork();
        die unless defined $pid;
        if ($pid) {
            $children{$pid} = 1;
        } else {
            local %SIG;
            my $cv = AE::cv { 
                exit 0;
            };
            $SIG{TERM} = sub { $cv->send };

            # We want to handle 1 at a time
            my $w; $w = AE::io $socket, 0, sub {
                return unless $socket;

                my $fh;
                my $peer = accept $fh, $socket;
                return unless $peer;

                AE::now_update;
                fh_nonblocking($fh, 1); # POSIX requires inheritance, the outside world does not
                $self->on_accept->( $fh, $context );
            };
            $cv->recv;
        }
    }

    foreach my $childpid (keys %children) {
        my $chld; $chld = AE::child $childpid, sub {
            delete $children{$childpid};
            undef $chld;
            $self->on_stop->() if scalar keys %children == 0;
        };
    }
}

1;

