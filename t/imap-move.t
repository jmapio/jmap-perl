#!/usr/bin/perl
# t/imap-move.t -- moving and destroying Emails on an IMAP backend: a move
# between two folders is one MOVE, a failed COPY never deletes the original,
# and whatever the server confirms gone leaves imessages straight away, so
# the sync after the write need not SEARCH the folder to find out.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON;
use lib '.';

$ENV{JMAP_DATADIR} = tempdir(CLEANUP => 1);
require JMAP::ImapDB;
require JMAP::Sync::Common;

# --- Sync::Common::imap_move against a fake IMAP connection -------------------

{
  package FakeIMAP;
  sub new               { my ($class, %args) = @_; bless { caps => {}, fail => {}, log => [], %args }, $class }
  sub capability        { $_[0]{caps} }
  sub get_response_code { 7 }
  sub _cmd              { my ($Self, $cmd) = @_; push @{$Self->{log}}, $cmd; $Self->{fail}{$cmd} ? undef : 'ok' }
  sub select            { $_[0]->_cmd('select') }
  sub unselect          { $_[0]->_cmd('unselect') }
  sub close             { $_[0]->_cmd('close') }
  sub move              { $_[0]->_cmd('move') }
  sub copy              { $_[0]->_cmd('copy') }
  sub store             { $_[0]->_cmd('store') }
  sub uidexpunge        { $_[0]->_cmd('uidexpunge') }
  sub logout            {}
}

sub imap_move {
  my ($imap, @args) = @_;
  my $backend = bless { imap => $imap, auth => {} }, 'JMAP::Sync::Common';
  return $backend->imap_move(@args);
}

{
  my $imap = FakeIMAP->new(caps => { move => 1, unselect => 1 });
  my $res = imap_move($imap, 'INBOX', 7, [10], 'Trash');
  is_deeply($imap->{log}, [qw(select move unselect)], 'MOVE capability: one MOVE');
  is_deeply($res->{moved}, [10], '... reported moved');
}
{
  my $imap = FakeIMAP->new(caps => { unselect => 1 });
  my $res = imap_move($imap, 'INBOX', 7, [10], 'Trash');
  is_deeply($imap->{log}, [qw(select copy store uidexpunge unselect)], 'no MOVE: COPY, STORE, EXPUNGE');
  is_deeply($res->{moved}, [10], '... reported moved');
}
{
  my $imap = FakeIMAP->new(caps => { move => 1, unselect => 1 });
  my $res = imap_move($imap, 'INBOX', 7, [10]);
  is_deeply($imap->{log}, [qw(select store uidexpunge unselect)], 'no destination: STORE and EXPUNGE');
  is_deeply($res->{moved}, [10], '... reported moved');
}
{
  my $imap = FakeIMAP->new(caps => { unselect => 1 }, fail => { uidexpunge => 1 });
  my $res = imap_move($imap, 'INBOX', 7, [10]);
  ok(!$res->{moved}, 'a refused EXPUNGE is not moved');
  is_deeply($res->{notMoved}, [10], '... but notMoved');
  is($imap->{log}[-1], 'unselect', '... and the folder is still unselected');
}
{
  my $imap = FakeIMAP->new(caps => { unselect => 1 }, fail => { copy => 1 });
  my $res = imap_move($imap, 'INBOX', 7, [10], 'Trash');
  is_deeply($imap->{log}, [qw(select copy unselect)], 'a refused COPY stores no \\Deleted');
  is_deeply($res->{notMoved}, [10], '... and is notMoved');
}
{
  my $imap = FakeIMAP->new(caps => { move => 1, unselect => 1 }, fail => { move => 1 });
  my $res = imap_move($imap, 'INBOX', 7, [10], 'Trash');
  is_deeply($res->{notMoved}, [10], 'a refused MOVE is notMoved');
}
{
  my $imap = FakeIMAP->new(caps => { move => 1, unselect => 1 });
  my $res = imap_move($imap, 'INBOX', 6, [10], 'Trash');
  is_deeply($imap->{log}, [qw(select)], 'a changed UIDVALIDITY touches nothing');
  ok(!$res->{moved}, '... and moves nothing');
}

# --- ImapDB update_messages / destroy_messages with a fake backend ------------

my (@calls, %fail);
{
  package FakeBackend;
  sub new             { bless {}, shift }
  sub connection_lost { 0 }
  sub imap_move {
    my ($Self, $name, $uv, $uids, $newname) = @_;
    push @calls, ['imap_move', $name, [@$uids], $newname];
    return $fail{move}{$uids->[0]} ? { notMoved => $uids } : { moved => $uids };
  }
  sub imap_copy {
    my ($Self, $name, $uv, $uid, $newname) = @_;
    push @calls, ['imap_copy', $name, $uid, $newname];
    return $fail{copy}{$uid} ? { notCopied => $uid } : { copied => $uid };
  }
}

my $db = JMAP::ImapDB->new('movetest');
$db->{change_cb} = sub {};
$db->{backend} = FakeBackend->new();

my %FOLDER = (1 => ['INBOX', 'inbox'], 2 => ['Trash', 'trash'], 3 => ['Archive', 'archive']);
$db->begin();
for my $id (sort keys %FOLDER) {
  my ($name, $role) = @{$FOLDER{$id}};
  $db->dinsert('ifolders', { ifolderid => $id, jmailboxid => "j$role", sep => '/', imapname => $name,
                             uidvalidity => 7, uidfirst => 1, uidnext => 100, highestmodseq => 1 });
  $db->dinsert('jmailboxes', { jmailboxid => "j$role", role => $role, name => $name, active => 1 });
}
# msgid => [ifolderid, uid], ...
my %MSG = (
  m1 => [[1, 10]],
  m2 => [[1, 11], [1, 12]],
  m3 => [[1, 13]],
  m4 => [[1, 14]],
  m5 => [[1, 15], [3, 30]],
  m6 => [[1, 16]],
  m7 => [[1, 17]],
  m8 => [[1, 18]],
  m9 => [[1, 19]],
);
for my $msgid (sort keys %MSG) {
  $db->dinsert('imessages', { ifolderid => $_->[0], uid => $_->[1], msgid => $msgid, thrid => "t$msgid",
                              flags => '[]', labels => '[]' }) for @{$MSG{$msgid}};
}
$db->commit();

sub rows {
  my $msgid = shift;
  $db->begin();
  my $rows = $db->dget('imessages', { msgid => $msgid }, 'ifolderid,uid');
  $db->commit();
  return [ sort { $a->[0] <=> $b->[0] or $a->[1] <=> $b->[1] } map { [$_->{ifolderid}, $_->{uid}] } @$rows ];
}
sub queued {
  my $msgid = shift;
  $db->begin();
  my $n = $db->dgetfield('imsgidtodo', { msgid => $msgid }, 'msgid');
  $db->commit();
  return $n;
}
sub update {
  my ($msgid, @mboxes) = @_;
  @calls = ();
  return $db->update_messages({ $msgid => { mailboxIds => { map { ("j$_" => JSON::true) } @mboxes } } }, sub { shift });
}

{
  my ($changed, $notchanged) = update('m1', 'trash');
  is_deeply(\@calls, [['imap_move', 'INBOX', [10], 'Trash']], 'into the trash: a single MOVE');
  ok(exists $changed->{m1}, '... updated');
  is_deeply(rows('m1'), [], '... and gone from INBOX in imessages at once');
  ok(queued('m1'), '... queued for the JMAP sync');
}
{
  update('m2', 'trash');
  is_deeply(\@calls, [['imap_move', 'INBOX', [11], 'Trash'], ['imap_move', 'INBOX', [12], undef]],
    'a duplicate in the source: one copy moved, the other expunged');
  is_deeply(rows('m2'), [], '... both gone from imessages');
}
{
  update('m3', 'trash', 'archive');
  is_deeply(\@calls, [['imap_copy', 'INBOX', 13, 'Archive'], ['imap_move', 'INBOX', [13], 'Trash']],
    'to two new folders: COPY to one, then MOVE to the other');
}
{
  update('m4', 'inbox', 'archive');
  is_deeply(\@calls, [['imap_copy', 'INBOX', 14, 'Archive']], 'only adding a folder: COPY, nothing removed');
  is_deeply(rows('m4'), [[1, 14]], '... INBOX row kept');
}
{
  update('m5', 'archive');
  is_deeply(\@calls, [['imap_move', 'INBOX', [15], undef]], 'only removing a folder: EXPUNGE there');
  is_deeply(rows('m5'), [[3, 30]], '... the other folder\'s row kept');
}
{
  $fail{move}{16} = 1;
  my ($changed, $notchanged) = update('m6', 'trash');
  ok($notchanged->{m6}, 'a refused MOVE is notUpdated');
  is_deeply(rows('m6'), [[1, 16]], '... and keeps its row');
}
{
  $fail{copy}{17} = 1;
  my ($changed, $notchanged) = update('m7', 'trash', 'archive');
  is_deeply(\@calls, [['imap_copy', 'INBOX', 17, 'Archive']], 'a refused COPY: the original is not touched');
  ok($notchanged->{m7}, '... notUpdated');
  is_deeply(rows('m7'), [[1, 17]], '... row kept');
}
{
  @calls = ();
  my ($destroyed, $notdestroyed) = $db->destroy_messages(['m8']);
  is_deeply(\@calls, [['imap_move', 'INBOX', [18], undef]], 'destroy: EXPUNGE');
  is_deeply($destroyed, ['m8'], '... destroyed');
  is_deeply(rows('m8'), [], '... and gone from imessages');
}
{
  @calls = ();
  $fail{move}{19} = 1;
  $db->destroy_messages(['m9']);
  is_deeply(rows('m9'), [[1, 19]], 'destroy the server refused: the row stays for the sync to judge');
}

done_testing;
