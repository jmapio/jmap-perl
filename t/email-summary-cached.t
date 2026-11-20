#!/usr/bin/perl
# A message's summary (preview, hasAttachment) is fetched once.  Whether it
# has been is jrawmessage.summarised, not whether there is a preview: a
# message with no text part has none, and was fetched again for every
# listing.  Its preview is "" (RFC 8621 S4.1.4: a String), not null.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use lib '.';

$ENV{JMAP_DATADIR} = tempdir(CLEANUP => 1);
require JMAP::ImapDB;
require JMAP::API;

my $db = JMAP::ImapDB->new('sum');
my $api = JMAP::API->new($db);

$db->begin();
my $folder = $db->dinsert('ifolders', { sep => '/', imapname => 'INBOX', label => 'INBOX', uidvalidity => 7, uidnext => 3, uidfirst => 1 });
$db->dmake('jmailboxes', { jmailboxid => 'mb', name => 'Inbox', role => 'inbox', active => 1 });
for ([1, 'Mpdf'], [2, 'Mtext']) {
  my ($uid, $msgid) = @$_;
  $db->dinsert('imessages', { ifolderid => $folder, uid => $uid, msgid => $msgid, thrid => "T$uid",
                              flags => '[]', labels => '[]', envelope => '{}', size => 10, internaldate => $uid });
  $db->add_message({ msgid => $msgid, thrid => "T$uid", internaldate => $uid, keywords => {},
                     isDraft => 0, isUnread => 1 }, ['mb']);
}
$db->commit();

# the IMAP side: what each message's summary is, and how often it is asked
my @asked;
my %summary = (1 => { preview => undef, hasAttachment => 1 },   # a PDF and nothing else
               2 => { preview => 'Hello there', hasAttachment => 0 });
no warnings qw(redefine once);
*JMAP::ImapDB::backend_cmd = sub {
  my ($self, $cmd, $imapname, $uidvalidity, $uids) = @_;
  die "unexpected $cmd" unless $cmd eq 'imap_summary';
  push @asked, $uids;
  return { data => { map { $_ => $summary{$_} } split /,/, $uids } };
};

my $list = sub {
  my ($r) = $api->api_Email_get({ accountId => 'sum', ids => ['Mpdf', 'Mtext'], properties => ['preview', 'hasAttachment'] });
  return { map { $_->{id} => $_ } @{ $r->[1]{list} } };
};

my $first = $list->();
is_deeply(\@asked, ['1,2'], 'the first listing fetches both summaries, in one go');
is($first->{Mpdf}{preview}, '', 'no text part: an empty preview, not null');
ok($first->{Mpdf}{hasAttachment}, 'and its attachment');
is($first->{Mtext}{preview}, 'Hello there', 'a text part: its preview');

@asked = ();
my $again = $list->();
is_deeply(\@asked, [], 'the next listing fetches nothing, the empty preview included');
is_deeply($again, $first, 'and answers the same');

# a database from before the marker: rows with a preview were summarised
{
  require DBI;
  my $file = "$ENV{JMAP_DATADIR}/old18.sqlite3";
  JMAP::ImapDB->new('old18');
  my $dbh = DBI->connect("dbi:SQLite:dbname=$file", undef, undef, { RaiseError => 1 });
  $dbh->do('ALTER TABLE jrawmessage DROP COLUMN summarised');
  $dbh->do("INSERT INTO jrawmessage (msgid, preview, hasAttachment) VALUES ('had', 'a preview', 0), ('never', NULL, 1)");
  $dbh->do('PRAGMA user_version = 18');
  $dbh->disconnect;
  JMAP::ImapDB->new('old18');
  $dbh = DBI->connect("dbi:SQLite:dbname=$file", undef, undef, { RaiseError => 1 });
  is(($dbh->selectrow_array('PRAGMA user_version'))[0], 19, 'v18 migrates to the current version');
  is_deeply($dbh->selectcol_arrayref('SELECT msgid FROM jrawmessage WHERE summarised IS NOT NULL ORDER BY msgid'),
            ['had'], 'a row with a preview counts as summarised; one without is worked out again, once');
}

done_testing;
