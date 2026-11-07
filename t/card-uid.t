#!/usr/bin/perl
# A vCard without UID gets no uid from Text::JSContact (JSContact 2.0,
# RFC 9982), so the proxy, which files cards by uid, gives it one made from
# its href: the same on every sync.
use strict;
use warnings;
use Test::More;
use lib '.';
use File::Temp qw(tempdir);
BEGIN { $ENV{JMAP_DATADIR} = tempdir(CLEANUP => 1) }
use JMAP::DB;

my $href = '/dav/addressbooks/user/u/Default/no-uid.vcf';
my $uid = JMAP::DB::card_uid_for_href($href);
like($uid, qr/\Aurn:uuid:[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/,
     'a version 5 UUID URN');
is(JMAP::DB::card_uid_for_href($href), $uid, 'the same href, the same uid');
isnt(JMAP::DB::card_uid_for_href("$href.2"), $uid, 'another href, another uid');

my $db = bless {}, 'JMAP::DB';
my $card = $db->parse_card("BEGIN:VCARD\nVERSION:4.0\nFN:Bob\nEND:VCARD\n", $href);
is($card->{uid}, $uid, 'parse_card: a vCard without UID gets the href uid');
is($db->parse_card("BEGIN:VCARD\nVERSION:4.0\nUID:urn:uuid:x1\nFN:Ann\nEND:VCARD\n", $href)->{uid},
   'urn:uuid:x1', 'a vCard UID is kept');

done_testing;
