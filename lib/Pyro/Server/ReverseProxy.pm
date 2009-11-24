package Pyro::Server::ReverseProxy;
use Any::Moose;
use AnyEvent;
use AnyEvent::Socket;
use namespace::clean -except => qw(meta);

our $qr_nl   = qr{\015?\012};
our $qr_nlnl = qr{(?<![^\012])\015?\012};
extends 'Pyro::Server';
with 'Pyro::PreforkServer';

has backends => (
    is => 'ro',
    isa => 'ArrayRef',
    required => 1,
);

has open_connections => (
    init_arg => undef,
    is => 'ro',
    isa => 'HashRef',
    default => sub { +{} }
);

has max_connections_per_host => (
    is => 'ro',
    isa => 'Int',
    default => 8,
);

# max connections per host is controlled via a Guard object which will
# decrease the count of active connections per host
sub _drain_request {
    my ($self, $host) = @_;
    my $connections = $self->open_connections;
    my $max_per_host = $self->max_connections_per_host;
    my $slot = $connections->{$host};
    while ($slot->[0] < $max_per_host) {
        if (my $cb = shift @{ $slot->[1] }) {
            # somebody wants that slot
            ++$slot->[0];
            $cb->(AnyEvent::Util::guard {
                --$slot->[0];
                $self->_drain_request($host);
            });
        } else {
            # nobody wants the slot, maybe we can forget about it
            delete $connections->{$host} unless $slot->[0];
            last;
        }
    }
}

sub _schedule_request {
    my ($self, $host, $cb) = @_;
    push @{ $self->open_connections->{$host}[1] }, $cb;

    $self->_drain_request($host);
}

sub choose_backend {
    my $self = shift;
    my $backends = $self->backends;
    $backends->[int(rand(scalar(@$backends)))];
}

sub process_request {
    my ($self, $request) = @_;

    # we're a pass-through proxy, so it's the server's darn responsibility
    # to work bad urls and such. go go

    # first the headers
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
}

sub proxy_request {
    my ($self, $request) = @_;

    my $timeout = 30;
    my $backend = $self->choose_backend();

use Data::Dumper;
    my $cb = sub { die Dumper(\@_) };
    my %state = (connect_guard => 1);
    $self->_schedule_request($backend, sub {
        $state{slot_guard} = shift;
        return unless $state{connect_guard};

        my ($host, $port) = split(/:/, $backend);
warn "connecting to $host $port";
        $state{connect_guard} = tcp_connect $host, $port, sub {
            $state{fh} = shift or do {
                my $err = "$!";
                %state = ();
                return $cb->(undef, { Status => 599, Reason => $err, });
            };

            pop; # free memory, save a tree

            return unless delete $state{connect_guard};

            # get handle
            $state{handle} = new AnyEvent::Handle
                fh       => $state{fh},
                timeout  => $timeout,
                peername => $host,
            ;

            # (re-)configure handle
            $state{handle}->on_error (sub {
                %state = ();
                $cb->(undef, { Status => 599, Reason => $_[2], });
            });
            $state{handle}->on_eof (sub {
                %state = ();
                $cb->(undef, { Status => 599, Reason => "Unexpected end-of-file", });
            });

            # send request
            my $method = $request->method;
            my $uri    = $request->uri;
            $state{handle}->push_write (
                "$method $uri HTTP/1.0\015\012"
                . $request->headers->as_string
                . "\015\012"
                . ($request->content || '')
            );

            # status line
            $state{handle}->push_read (line => $qr_nl, sub {
                $_[1] =~ /^HTTP\/([0-9\.]+) \s+ ([0-9]{3}) (?: \s+ ([^\015\012]*) )?/ix
                    or return (%state = (), $cb->(undef, { Status => 599, Reason => "Invalid server response ($_[1])", }));

                my $response = $request->response;
                $response->protocol($1);
                $response->code($2);
                $response->message($3);

                # headers, could be optimized a bit
                $state{handle}->unshift_read (line => $qr_nlnl, sub {
                    my %hdr;
                    for ("$_[1]") {
                        y/\015//d; # weed out any \015, as they show up in the weirdest of places.

                        # things seen, not parsed:
                        # p3pP="NON CUR OTPi OUR NOR UNI"

                        $hdr{lc $1} .= ",$2"
                            while /\G
                                ([^:\000-\037]*):
                                [\011\040]*
                                ((?: [^\012]+ | \012[\011\040] )*)
                                \012
                            /gxc;
    
                        /\G$/
                            or return (%state = (), $cb->(undef, { Status => 599, Reason => "Garbled response headers", }));
                    }

                    substr $_, 0, 1, "" for values %hdr;
                    $response->push_header($_, $hdr{$_}) for keys %hdr;

                    my $finish; $finish = sub {
                        $state{handle}->destroy if $state{handle};
                        %state = ();
                        $request->finalize();
                        undef $finish;
                    };

                    my $len = $hdr{"content-length"};

                    if ( $response->code =~ /^(?:1..|[23]04)$/
                        or $method eq "HEAD"
                        or (defined $len && !$len)
                    ) {
                        # no body
                        $finish->("", \%hdr);
                    } else {
                        $state{handle}->push_read(chunk => $len, sub {
                            $request->respond_headers;
                            $response->content( $_[1] );
                            $request->respond_body();
                            $finish->("TBD", \%hdr);
                        });
                    }
                });
            });
        };
    });

    defined wantarray && AnyEvent::Util::guard { %state = () }
}

1;