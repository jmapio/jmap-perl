#!/usr/bin/perl
# t/msgid.t -- an Email's id: the server's RFC 8474 EMAILID where there is one,
# else a hash of the ENVELOPE and RFC822.SIZE, so a copy delivered back to its
# sender (same headers, more bytes) is a different Email, and an identical
# re-upload is the same one.
use strict;
use warnings;
use Test::More;
use JSON::XS;
use lib '.';
require JMAP::ImapDB;

my $env = { Subject => 'hi', From => 'a@example.com', 'Message-ID' => '<x@y>', Date => 'Fri, 6 Nov 2026 10:00:00 +0000' };
my $id = sub { JMAP::ImapDB::_msgid_for({ envelope => $_[0], 'rfc822.size' => $_[1], ($_[2] ? (emailid => $_[2]) : ()) }) };

is($id->($env, 830), $id->($env, 830), 'the same envelope and size give the same id');
is($id->($env, 830), $id->($env, '830'), 'a size as a string or a number gives the same id');
isnt($id->($env, 830), $id->($env, 1012), 'a different size (a delivered copy) gives a different id');
isnt($id->($env, 830), $id->({ %$env, Subject => 'ho' }, 830), 'a different envelope gives a different id');
like($id->($env, 830), qr/\Am[0-9a-f]{15}\z/, 'a hashed id is a valid JMAP Id');

# rekey_folder hashes the envelope as stored: JSON in, the same id out
my $stored = decode_json(JSON::XS->new->utf8->canonical->encode($env));
is($id->($stored, 830), $id->($env, 830), 'an envelope from storage gives the id a fetch would');

is($id->($env, 830, ['Mfc4878a6eaf1d2b535ddd2bc']), 'Mfc4878a6eaf1d2b535ddd2bc', "the server's EMAILID wins");
is($id->($env, 830, ['NIL']), $id->($env, 830), 'a NIL EMAILID falls back to the hash');
is($id->($env, 830, ['bad id!']), $id->($env, 830), 'so does one that is not a valid Id');

done_testing;
