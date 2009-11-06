use inc::Module::Install;

name('Pyro');
all_from('lib/Pyro.pm');

requires 'namespace::clean';
requires 'AnyEvent';
requires 'AnyEvent::Handle';
requires 'AnyEvent::Socket';
requires 'Coro';           # XXX do we need this?
requires 'Coro::AnyEvent'; # XXX do we need this?
requires 'HTTP::Date';
requires 'HTTP::Request';
requires 'HTTP::Response';
requires 'Moose' => 0.92; # native traits
requires 'MooseX::Getopt';
requires 'MooseX::NonMoose';
requires 'MooseX::SimpleConfig';
requires 'URI';

test_requires 'IO::Socket::INET';
test_requires 'POSIX';
test_requires 'Plack';
test_requires 'Plack::Request';
test_requires 'Test::SharedFork';

WriteAll;