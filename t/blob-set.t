#!/usr/bin/perl
# draft-ietf-jmap-blobext-03: Blob/set's SetErrors, the whole-blob size and
# digest:<algorithm> checks, no ifInState, and Blob/get's chunks defaults.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use MIME::Base64 ();
use Digest::SHA ();
use lib '.';

$ENV{JMAP_DATADIR} = tempdir(CLEANUP => 1);
require JMAP::ImapDB;
require JMAP::API;

my $api = JMAP::API->new(JMAP::ImapDB->new('bx'));
my $call = sub {
  my ($m, $a, $cap) = @_;
  my $r = $api->handle_request({ using => ['urn:ietf:params:jmap:core', 'urn:ietf:params:jmap:' . ($cap // 'blob2')],
                                 methodCalls => [[$m, { accountId => 'bx', %$a }, 't']] });
  return (grep { $_->[2] eq 't' } @{ ref $r eq 'HASH' ? $r->{methodResponses} : $r })[0];
};
my $set = sub { $call->('Blob/set', { create => { c => $_[0] } })->[1] };
my $sha = MIME::Base64::encode_base64(Digest::SHA::sha256('hello'), '');

my $ok = $set->({ data => [{ 'data:asText' => 'hello' }], size => 5, 'digest:sha-256' => $sha });
ok($ok->{created}{c}, 'size and digest that match: created') or diag explain $ok;
is_deeply($set->({ data => [{ 'data:asText' => 'hello' }], size => 6 })->{notCreated}{c}{properties}, ['size'], 'a wrong size');
is_deeply($set->({ data => [{ 'data:asText' => 'hello' }], 'digest:sha-256' => 'AAAA' })->{notCreated}{c}{properties},
          ['digest:sha-256'], 'a wrong digest');
is_deeply($set->({ data => [{ 'data:asText' => 'hello' }], 'digest:sha3-256' => 'AAAA' })->{notCreated}{c}{properties},
          ['digest:sha3-256'], 'an algorithm the server does not list is rejected, not ignored');
my $bad = $set->({ data => [{ 'data:asBase64' => '!!!' }] })->{notCreated}{c};
is_deeply([ $bad->{type}, $bad->{properties} ], [ 'invalidProperties', ['data'] ], 'invalid base64: invalidProperties ["data"]');
is($set->({ data => [{ blobId => 'Gnope' }] })->{notCreated}{c}{type}, 'notFound', 'a blobId that does not exist: notFound');
my $r = $call->('Blob/set', { ifInState => 'x', create => {} });
is_deeply([ $r->[0], $r->[1]{type} ], [ 'error', 'invalidArguments' ], 'ifInState: invalidArguments');
is_deeply([ @{ $call->('Blob/set', { create => {} })->[1] }{qw(oldState newState)} ], [ undef, undef ], 'no states');

my $id = $ok->{created}{c}{id};
my $g = $call->('Blob/get', { ids => [$id], properties => ['chunks'] })->[1]{list}[0];
is_deeply($g->{chunks}, [ { blobId => $id, offset => 0, length => 5 } ], 'chunks: one, by default with blobId, offset and length');

# RFC 9404's Blob/upload keeps its own errors
my $u = $call->('Blob/upload', { create => { u => { data => [{ blobId => 'Gnope' }] } } }, 'blob')->[1]{notCreated}{u};
is($u->{type}, 'blobNotFound', 'Blob/upload: blobNotFound as RFC 9404 has it');

done_testing;
