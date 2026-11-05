#!/usr/bin/perl
# Calendar and AddressBook names and descriptions with non-ASCII characters.
# DBD::SQLite (without sqlite_unicode) hands text back as the UTF-8 bytes it
# stored; passed on as they are, JSON::XS->utf8 encodes every byte again and
# "Persönlicher Kalender" reaches the client as "PersÃ¶nlicher Kalender".
use strict;
use warnings;
use utf8;
use Test::More;
use lib '.';
use JSON::XS;
use File::Temp qw(tempdir);
BEGIN { $ENV{JMAP_DATADIR} = tempdir(CLEANUP => 1) }
use JMAP::API;
require JMAP::ImapDB;

my $db = JMAP::ImapDB->new('collectionnameutf8');
my $api = JMAP::API->new($db);
my $json = JSON::XS->new->utf8->canonical;

$db->begin();
my $calid = $db->dmake('jcalendars', { name => 'Persönlicher Kalender', description => 'Grüße', color => '#3a87ad', isVisible => 1 });
my $abid  = $db->dmake('jaddressbooks', { name => 'Bürokontakte', description => 'Österreich', isVisible => 1 });
$db->commit();

my ($cal) = @{ $api->api_Calendar_get({})->[1]{list} };
is($cal->{name}, 'Persönlicher Kalender', 'Calendar/get: the name as stored');
is($cal->{description}, 'Grüße', 'Calendar/get: the description as stored');
like($json->encode($cal), qr/"name":"Pers\x{c3}\x{b6}nlicher Kalender"/, 'Calendar/get: encoded once as UTF-8');

my ($ab) = @{ $api->api_AddressBook_get({})->[1]{list} };
is($ab->{name}, 'Bürokontakte', 'AddressBook/get: the name as stored');
is($ab->{description}, 'Österreich', 'AddressBook/get: the description as stored');

# A value that is not valid UTF-8 (written by something else) is passed on, not dropped
$db->begin();
$db->dbh->do('UPDATE jcalendars SET name = ? WHERE jcalendarid = ?', {}, "Kalender \xF6", $calid);
$db->commit();
($cal) = @{ $api->api_Calendar_get({})->[1]{list} };
is($cal->{name}, "Kalender \xF6", 'invalid UTF-8 is passed on as it is');

# Absent descriptions stay null
$db->begin();
$db->dbh->do('UPDATE jcalendars SET description = NULL');
$db->dbh->do('UPDATE jaddressbooks SET description = NULL');
$db->commit();
($cal) = @{ $api->api_Calendar_get({})->[1]{list} };
($ab)  = @{ $api->api_AddressBook_get({})->[1]{list} };
ok(!defined $cal->{description}, 'Calendar/get: no description is null');
ok(!defined $ab->{description}, 'AddressBook/get: no description is null');

done_testing;
