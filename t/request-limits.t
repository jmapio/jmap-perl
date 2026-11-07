#!/usr/bin/perl
# RFC 8620 S5.1/S5.3: a /get with more ids than maxObjectsInGet, or a /set
# with more objects than maxObjectsInSet, is requestTooLarge.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use lib '.';

$ENV{JMAP_DATADIR} = tempdir(CLEANUP => 1);
require JMAP::ImapDB;
require JMAP::API;

my $api = JMAP::API->new(JMAP::ImapDB->new('lim'));
my $call = sub {
  my ($method, $args) = @_;
  my $r = $api->handle_request({ using => ['urn:ietf:params:jmap:core', 'urn:ietf:params:jmap:mail'],
                                 methodCalls => [[$method, { accountId => 'lim', %$args }, 't']] });
  return (grep { $_->[2] eq 't' } @{ ref $r eq 'HASH' ? $r->{methodResponses} : $r })[0];
};
my $G = $JMAP::Capabilities::MAX_OBJECTS_IN_GET;
my $S = $JMAP::Capabilities::MAX_OBJECTS_IN_SET;
is($call->('Mailbox/get', { ids => [ map { "m$_" } 1 .. $G + 1 ] })->[1]{type}, 'requestTooLarge', 'one id too many');
is($call->('Mailbox/get', { ids => [ map { "m$_" } 1 .. 3 ] })->[0], 'Mailbox/get', 'a few is fine');
is($call->('Mailbox/set', { destroy => [ map { "m$_" } 1 .. $S ], update => { x => {} } })->[1]{type},
   'requestTooLarge', 'create + update + destroy over maxObjectsInSet');

done_testing;
