#!/usr/bin/perl
# One ContactCard per UID, in every address book holding a copy of it: the
# copies are its addressBookIds.  A copy that goes takes only its address
# book from addressBookIds; the last takes the card.  Destroying the card
# deletes every copy; an update changes every copy, and a change to
# addressBookIds adds or deletes copies.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::XS ();
use lib '.';

$ENV{JMAP_DATADIR} = tempdir(CLEANUP => 1);
require JMAP::ImapDB;
require JMAP::API;

{
  package FakeCardDAV;
  our @calls;
  sub new { bless {}, shift }
  sub connection_lost { 0 }
  sub AUTOLOAD { our $AUTOLOAD; (my $m = $AUTOLOAD) =~ s/.*:://; return if $m eq 'DESTROY';
                 push @calls, [$m, @_[1..$#_]]; return $m =~ /^(copy|new)_card$/ ? "$_[1]made.vcf" : 1 }
  sub can { 1 }
}

my $db = JMAP::ImapDB->new('cardbooks');
$db->{backend} = FakeCardDAV->new;
my $api = JMAP::API->new($db);
no warnings qw(redefine once);
*JMAP::ImapDB::sync_addressbooks = sub { };

my $vcf = "BEGIN:VCARD\r\nVERSION:4.0\r\nUID:urn:uuid:k1\r\nFN:Ann\r\nEND:VCARD\r\n";
$db->begin();
my ($ja, $jb) = map { $db->dmake('jaddressbooks', { name => $_, active => 1 }) } qw(A B);
my $ia = $db->dinsert('iaddressbooks', { href => '/ab/A/', jaddressbookid => $ja, name => 'A' });
my $ib = $db->dinsert('iaddressbooks', { href => '/ab/B/', jaddressbookid => $jb, name => 'B' });
$db->dinsert('icards', { iaddressbookid => $ia, uid => 'urn:uuid:k1', kind => 'individual', href => '/ab/A/k1.vcf', etag => 'a' });
$db->dinsert('icards', { iaddressbookid => $ib, uid => 'urn:uuid:k1', kind => 'individual', href => '/ab/B/k1.vcf', etag => 'b' });
$db->write_card_vcf('urn:uuid:k1', $vcf);
$db->set_card($db->_card_books('k1'), { uid => 'urn:uuid:k1', '@type' => 'Card', version => '2.0', name => { full => 'Ann' } });
$db->commit();

my $get = sub { my ($r) = $api->api_ContactCard_get({ accountId => 'cardbooks', ids => ['k1'],
  properties => ['addressBookIds'] }); return $r->[1]{list}[0] };
is_deeply([sort keys %{ $get->()->{addressBookIds} }], [sort ($ja, $jb)], 'addressBookIds holds both address books');
for my $ab ($ja, $jb) {
  my ($q) = $api->api_ContactCard_query({ accountId => 'cardbooks', filter => { inAddressBook => "$ab" } });
  is_deeply($q->[1]{ids}, ['k1'], "inAddressBook $ab finds it");
}

# one copy goes: the card stays, in the other book
$db->begin();
$db->ddelete('icards', { href => '/ab/A/k1.vcf' });
$db->_card_copy_gone('urn:uuid:k1', 'individual');
$db->commit();
is_deeply([keys %{ $get->()->{addressBookIds} }], ["$jb"], 'one copy gone: the card stays, in the other book');

# its book goes: so does the card
$db->begin();
$db->ddelete('icards', { iaddressbookid => $ib });
$db->ddelete('iaddressbooks', { iaddressbookid => $ib });
$db->sync_jaddressbooks();
$db->commit();
ok(!$get->(), 'with the last copy gone, so is the card');

# back in both, for the writes
$db->begin();
$ib = $db->dinsert('iaddressbooks', { href => '/ab/B/', name => 'B' });
$db->sync_jaddressbooks();
$jb = $db->dgetfield('iaddressbooks', { iaddressbookid => $ib }, 'jaddressbookid');
$db->dinsert('icards', { iaddressbookid => $_->[0], uid => 'urn:uuid:k1', kind => 'individual', href => $_->[1], etag => 'x' })
  for [$ia, '/ab/A/k1.vcf'], [$ib, '/ab/B/k1.vcf'];
$db->write_card_vcf('urn:uuid:k1', $vcf);
$db->set_card($db->_card_books('k1'), { uid => 'urn:uuid:k1', '@type' => 'Card', version => '2.0' });
$db->commit();

@FakeCardDAV::calls = ();
my ($changed, $not) = $db->update_contacts_jscontact({ k1 => { name => { full => 'Annie' } } });
ok(exists $changed->{k1}, 'updated') or diag explain $not;
is_deeply([sort map { $_->[1] } grep { $_->[0] eq 'update_card' } @FakeCardDAV::calls],
  ['/ab/A/k1.vcf', '/ab/B/k1.vcf'], 'an update changes every copy');

@FakeCardDAV::calls = ();
($changed, $not) = $db->update_contacts_jscontact({ k1 => { addressBookIds => { $jb => JSON::XS::true } } });
ok(exists $changed->{k1}, 'taking a book out of addressBookIds is an update') or diag explain $not;
is_deeply([map { [@$_[0,1]] } grep { $_->[0] eq 'delete_card' } @FakeCardDAV::calls],
  [['delete_card', '/ab/A/k1.vcf']], 'which deletes only that book\'s copy');

$db->begin(); $db->ddelete('icards', { href => '/ab/A/k1.vcf' }); $db->commit();
@FakeCardDAV::calls = ();
($changed, $not) = $db->update_contacts_jscontact({ k1 => { addressBookIds => { $ja => JSON::XS::true, $jb => JSON::XS::true } } });
is_deeply([map { [@$_[0..2]] } grep { $_->[0] eq 'copy_card' } @FakeCardDAV::calls],
  [['copy_card', '/ab/B/k1.vcf', '/ab/A/']], 'adding a book copies the card there') or diag explain $not;

$db->begin(); $db->dinsert('icards', { iaddressbookid => $ia, uid => 'urn:uuid:k1', kind => 'individual', href => '/ab/A/k1.vcf', etag => 'y' }); $db->commit();
@FakeCardDAV::calls = ();
my ($gone) = $db->destroy_contacts(['k1']);
is_deeply($gone, ['k1'], 'destroyed');
is_deeply([sort map { $_->[1] } grep { $_->[0] eq 'delete_card' } @FakeCardDAV::calls],
  ['/ab/A/k1.vcf', '/ab/B/k1.vcf'], 'destroying the card deletes every copy');

@FakeCardDAV::calls = ();
my ($made, $notmade) = $db->create_contacts_jscontact({ c1 => { '@type' => 'Card', version => '2.0', name => { full => 'Two' },
  addressBookIds => { $ja => JSON::XS::true, $jb => JSON::XS::true } } });
ok($made->{c1}, 'a card can be created in two address books') or diag explain $notmade;
is_deeply([sort map { $_->[1] } grep { $_->[0] eq 'new_card' } @FakeCardDAV::calls], ['/ab/A/', '/ab/B/'], 'a copy in each');

# a v15 database: each card in its one address book
{
  require DBI;
  my $file = "$ENV{JMAP_DATADIR}/old15.sqlite3";
  JMAP::ImapDB->new('old15');
  my $dbh = DBI->connect("dbi:SQLite:dbname=$file", undef, undef, { RaiseError => 1 });
  $dbh->do('DROP TABLE jcontacts');
  $dbh->do('CREATE TABLE jcontacts (contactuid TEXT PRIMARY KEY, jaddressbookid INTEGER, isFlagged BOOLEAN,'
         . ' jcreated INTEGER, jmodseq INTEGER, mtime DATE, active BOOLEAN)');
  $dbh->do("INSERT INTO jcontacts (contactuid, jaddressbookid, active) VALUES ('old', 4, 1)");
  $dbh->do('PRAGMA user_version = 15');
  $dbh->disconnect;
  JMAP::ImapDB->new('old15');
  $dbh = DBI->connect("dbi:SQLite:dbname=$file", undef, undef, { RaiseError => 1 });
  is(($dbh->selectrow_array('PRAGMA user_version'))[0], 16, 'v15 migrates to v16');
  is(($dbh->selectrow_array("SELECT jaddressbookids FROM jcontacts WHERE contactuid = 'old'"))[0], '4', 'a card keeps its address book');
}

done_testing;
