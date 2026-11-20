#!/usr/bin/perl
# Gmail's synthetic Archive: a message with no label sits in All Mail alone,
# which is not a mailbox here, so it is the Archive's.  From 2017 (f06ed8c)
# there was no Archive, and such mail was stored in a mailbox with no id:
# Email/get gave it mailboxIds {"": true}.
use strict;
use warnings;
use Test::More;
use JSON::XS ();
use File::Temp qw(tempdir);
use lib '.';

$ENV{JMAP_DATADIR} = tempdir(CLEANUP => 1);
require JMAP::ImapDB;
require JMAP::API;

my $db = JMAP::ImapDB->new('gm');
$db->{is_gmail} = 1;
my $api = JMAP::API->new($db);
my $json = JSON::XS->new->canonical;
sub count {
  my ($d, $sql) = @_;
  $d->begin();
  my ($n) = $d->dbh->selectrow_array($sql);
  $d->commit();
  return $n;
}

$db->begin();
my %folder;
for ([qw(INBOX \Inbox)], ['[Gmail]/All Mail', '\AllMail'], [qw(Work Work)], [qw(Archive Archive)]) {
  my ($imapname, $label) = @$_;
  $folder{$label} = $db->dinsert('ifolders', { sep => '/', imapname => $imapname, label => $label,
                                               uidvalidity => 1, uidnext => 1, uidfirst => 1 });
}
# one archived before there was an Archive: stored in no mailbox
my $env = $json->encode({ Subject => 'old', From => 'a@example.com' });
$db->dinsert('imessages', { ifolderid => $folder{'\AllMail'}, uid => 1, msgid => 'Mold',
  thrid => 'T1', flags => '[]', labels => '[]', envelope => $env, size => 10, internaldate => 1 });
$db->add_message({ msgid => 'Mold', thrid => 'T1', internaldate => 1, keywords => {},
                   isDraft => 0, isUnread => 1 }, [undef]);
$db->commit();

my $mailboxes = sub {
  my ($r) = $api->api_Mailbox_get({ accountId => 'gm' });
  return { map { ($_->{role} // $_->{name}) => $_ } @{ $r->[1]{list} } };
};
my $mailboxIds = sub {
  my ($r) = $api->api_Email_get({ accountId => 'gm', ids => [shift], properties => ['mailboxIds'] });
  return $r->[1]{list}[0]{mailboxIds};
};
is(count($db, 'SELECT COUNT(*) FROM jmessagemap WHERE jmailboxid IS NULL'), 1, 'stranded as it was: a mailbox with no id');
is_deeply($mailboxIds->('Mold'), {}, 'which Email/get no longer reports as {"": true}');
my ($before) = $api->api_Email_get({ accountId => 'gm', ids => [] });

$db->sync_jmailboxes();
my $mb = $mailboxes->();
my $archive = $mb->{archive};
ok($archive, 'Gmail has an Archive') or diag explain [keys %$mb];
is($archive->{name}, 'Archive', 'named so');
ok(!$archive->{myRights}{mayDelete} && !$archive->{myRights}{mayRename}, 'which cannot be renamed or deleted');
ok($mb->{Archive} && !defined $mb->{Archive}{role}, 'a label called Archive is a plain mailbox, not the archive');
is_deeply($mailboxIds->('Mold'), { $archive->{id} => JSON::XS::true }, 'the stranded message is in the Archive');
my ($changes) = $api->api_Email_changes({ accountId => 'gm', sinceState => $before->[1]{state} });
is_deeply($changes->[1]{updated}, ['Mold'], 'and clients see it move');
is(count($db, 'SELECT COUNT(*) FROM jmessagemap WHERE jmailboxid IS NULL'), 0, 'no row with no mailbox left');

# a new one with no label goes there too; one with a label does not
$db->begin();
$db->dinsert('imessages', { ifolderid => $folder{'\AllMail'}, uid => 2, msgid => 'Mnew',
  thrid => 'T2', flags => '[]', labels => '[]', envelope => $env, size => 10, internaldate => 2 });
$db->dinsert('imessages', { ifolderid => $folder{'\AllMail'}, uid => 3, msgid => 'Mwork',
  thrid => 'T3', flags => '[]', labels => '["Work"]', envelope => $env, size => 10, internaldate => 3 });
$db->sync_jmap_msgid($_) for qw(Mnew Mwork);
$db->commit();
is_deeply($mailboxIds->('Mnew'), { $archive->{id} => JSON::XS::true }, 'mail with no label is archived');
is_deeply($mailboxIds->('Mwork'), { $mb->{Work}{id} => JSON::XS::true }, 'mail with a label is in that mailbox alone');
is($mailboxes->()->{archive}{totalEmails}, 2, 'and the Archive counts what it holds');

# made once, and kept across syncs
$db->sync_jmailboxes();
is($mailboxes->()->{archive}{id}, $archive->{id}, 'the same Archive after another sync');
is(count($db, "SELECT COUNT(*) FROM jmailboxes WHERE role = 'archive'"), 1, 'and only one');

# not on any other server
my $plain = JMAP::ImapDB->new('plain');
$plain->begin();
$plain->dinsert('ifolders', { sep => '/', imapname => 'INBOX', label => 'INBOX', uidvalidity => 1, uidnext => 1, uidfirst => 1 });
$plain->commit();
$plain->sync_jmailboxes();
is(count($plain, "SELECT COUNT(*) FROM jmailboxes WHERE role = 'archive'"), 0,
   'no synthetic Archive anywhere but Gmail');

done_testing;
