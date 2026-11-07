#!/usr/bin/perl
# t/envelope-eai.t -- RFC 6532 headers through the stored envelope: the raw
# UTF-8 octets IMAP hands over come back as characters, decoded once.
use strict;
use warnings;
use utf8;
use Test::More;
use JSON::XS;
use Encode qw(encode_utf8);
use lib '.';
use JMAP::ImapDB;
use Data::JSEmail;

# As sync stores it: the ENVELOPE's octets, one character per byte, as JSON
my %env = (
  From    => encode_utf8('Jörg <jörg@bücher.example>'),
  To      => encode_utf8('田中 <田中@例え.jp>'),
  Subject => encode_utf8('Grüße aus Köln'),
);
my %d = JMAP::ImapDB::_envelopedata(JSON::XS->new->utf8->encode(\%env));

is($d{msgsubject}, 'Grüße aus Köln', 'a raw UTF-8 subject is decoded once');
ok(!utf8::is_utf8($d{msgfrom}) || $d{msgfrom} !~ /[^\x00-\xff]/, 'From is kept as octets');
is_deeply(Data::JSEmail::asAddresses($d{msgfrom}),
  [{ name => 'Jörg', email => 'jörg@bücher.example' }], 'and reads back as characters');
is(Data::JSEmail::asAddresses($d{msgto})->[0]{email}, '田中@例え.jp', 'To too');

my %ascii = JMAP::ImapDB::_envelopedata(JSON::XS->new->utf8->encode(
  { Subject => '=?UTF-8?Q?Gr=C3=BC=C3=9Fe?=', From => 'a@example.com' }));
is($ascii{msgsubject}, 'Grüße', 'encoded-words still decoded');

done_testing;
