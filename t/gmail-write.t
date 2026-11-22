#!/usr/bin/perl
#
# Writing to Gmail.  UIDs count per folder, so a message appended to Drafts
# is found in All Mail by its X-GM-MSGID, never by the APPENDUID; a label
# with a space goes out quoted, so Gmail does not split it in two; and a
# draft's X-GM-LABELS say \Draft while the folder is \Drafts, which must meet.

use strict;
use warnings;
use Test::More;
use Socket;
use IO::Handle;
use JSON::XS ();
use File::Temp qw(tempdir tempfile);
use lib '.';

$ENV{JMAP_DATADIR} = tempdir(CLEANUP => 1);
require Mail::IMAPTalk;
require JMAP::Sync::Gmail;
require JMAP::ImapDB;

my $json = JSON::XS->new->canonical;

# --- a scripted IMAP server at the other end of a socketpair -------------------
# Runs $code with a real Mail::IMAPTalk talking to a child that answers every
# command OK (APPEND with an APPENDUID, FETCH with an X-GM-MSGID) and returns
# the command lines the child was sent.

sub talk {
  my ($caps, $code) = @_;
  socketpair(my $client, my $server, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
  $_->autoflush(1) for $client, $server;
  my (undef, $logfile) = tempfile(UNLINK => 1);
  my $pid = fork() // die "fork: $!";
  unless ($pid) {
    close $client;
    open my $log, '>', $logfile or die;
    while (my $line = <$server>) {
      my ($tag, $cmd) = $line =~ /^(\S+) (?:uid )?(\S+)/i;
      $cmd = lc($cmd // '');
      if ($line =~ /\{(\d+)\}\r\n\z/) {                 # a literal follows
        print $server "+ go ahead\r\n";
        read($server, my $data, $1 + 2);
      }
      print $log $line;
      if ($cmd eq 'capability') {
        print $server "* CAPABILITY IMAP4rev1 UIDPLUS UNSELECT $caps\r\n";
      }
      elsif ($cmd eq 'select' or $cmd eq 'examine') {
        print $server "* OK [UIDVALIDITY 7] ok\r\n";
      }
      elsif ($cmd eq 'append') {
        print $server "$tag OK [APPENDUID 7 950] done\r\n";
        next;
      }
      elsif ($cmd eq 'fetch' and $caps =~ /X-GM-EXT-1/) {
        print $server "* 1 FETCH (UID 950 X-GM-MSGID 1700000000000000001)\r\n";
      }
      print $server "$tag OK done\r\n";
    }
    close $log;
    exit 0;
  }
  close $server;
  my $imap = Mail::IMAPTalk->new(Socket => $client, State => Mail::IMAPTalk::Authenticated(),
                                 Uid => 1, UseBlocking => 1) or die "IMAPTalk->new";
  my $backend = bless { auth => {}, imap => $imap }, 'JMAP::Sync::Gmail';
  my @res = $code->($backend);
  undef $backend;
  undef $imap;      # its LOGOUT while the server is still there to answer it
  close $client;
  waitpid($pid, 0);
  open my $in, '<', $logfile or die;
  my @lines = map { s/\r?\n\z//r } <$in>;
  return (\@lines, @res);
}

# --- imap_labels: a label with a space is one label ----------------------------

my ($sent) = talk('X-GM-EXT-1', sub { $_[0]->imap_labels('[Gmail]/All Mail', 7, 4242, ['Two Words', '\\Sent']) });
my ($store) = grep { /\bstore\b/i } @$sent;
like($store, qr/\bx-gm-labels \("Two Words" \\Sent\)$/i,
  'imap_labels: a label with a space goes out quoted, a system label as an atom');

# --- imap_append: the X-GM-MSGID of the appended message ------------------------

my $rfc822 = "Subject: test\r\nMessage-ID: <test\@example.com>\r\n\r\ntest\r\n";
my ($lines, $res) = talk('X-GM-EXT-1', sub {
  $_[0]->imap_append('[Gmail]/Drafts', '(\\Draft)', ' 1-Jan-2026 00:00:00 +0000', $rfc822) });
is_deeply($res, ['append', '[Gmail]/Drafts', 7, 950, '1700000000000000001'],
  'imap_append: with X-GM-EXT-1, the X-GM-MSGID comes back with the APPENDUID');
my ($fetchat) = grep { $lines->[$_] =~ /\bfetch\b/i } 0 .. $#$lines;
ok(defined $fetchat && grep({ /\bexamine "?\[Gmail\]\/Drafts"?/i } @$lines[0 .. $fetchat]),
  'imap_append: and is fetched in the folder the UID belongs to');

($lines, $res) = talk('', sub {
  $_[0]->imap_append('Drafts', '(\\Draft)', ' 1-Jan-2026 00:00:00 +0000', $rfc822) });
is_deeply($res, ['append', 'Drafts', 7, 950, undef], 'imap_append: without X-GM-EXT-1, no X-GM-MSGID');
ok(!grep({ /\bfetch\b/i } @$lines), 'imap_append: and no FETCH for one');

# --- labels(): a draft's \Draft is the \Drafts folder ---------------------------

my $db = JMAP::ImapDB->new('gw');
$db->{is_gmail} = 1;
$db->begin();
my %folder;
for (['INBOX', '\\Inbox'], ['[Gmail]/All Mail', '\\AllMail'], ['[Gmail]/Drafts', '\\Drafts'],
     ['Two Words', 'Two Words']) {
  my ($imapname, $label) = @$_;
  $folder{$label} = $db->dinsert('ifolders', { sep => '/', imapname => $imapname, label => $label,
                                               uidvalidity => 1, uidnext => 1, uidfirst => 1 });
}
my $labels = $db->labels();
$db->commit();
is($labels->{'\\Draft'} && $labels->{'\\Draft'}[0], $folder{'\\Drafts'}, 'labels: \\Draft is the \\Drafts folder');

$db->sync_jmailboxes();
$db->begin();
my $drafts = $db->dgetfield('jmailboxes', { role => 'drafts', active => 1 }, 'jmailboxid');
$db->dinsert('imessages', { ifolderid => $folder{'\\AllMail'}, uid => 1, msgid => 'Mdraft',
  thrid => 'Tdraft', flags => '["\\\\Draft"]', labels => '["\\\\Draft"]', size => 10, internaldate => 1,
  envelope => $json->encode({ Subject => 'draft' }) });
$db->sync_jmap_msgid('Mdraft');
my $in = $db->dgetcol('jmessagemap', { msgid => 'Mdraft', active => 1 }, 'jmailboxid');
$db->commit();
ok($drafts, 'there is a Drafts mailbox');
is_deeply($in, [$drafts], 'a draft labelled \\Draft becomes an Email in Drafts');

# --- import_message: found by X-GM-MSGID, not by the Drafts UID in All Mail ----

{
  no warnings 'redefine', 'once';
  # The draft gets UID 950 in Drafts.  In All Mail, UID 950 is an older,
  # unrelated message; the new one is UID 4242 there.
  local *JMAP::ImapDB::backend_cmd = sub {
    my ($self, $cmd) = @_;
    die "unexpected $cmd" unless $cmd eq 'imap_append';
    return ['append', '[Gmail]/Drafts', 1, 950, 'GMnew'];
  };
  local *JMAP::ImapDB::do_folder = sub {
    my ($self, $ifolderid) = @_;
    $self->begin();
    $self->dinsert('imessages', { ifolderid => $ifolderid, uid => 950, msgid => 'GMold', thrid => 'Told',
      flags => '[]', labels => '["Two Words","\\\\Sent"]', size => 10, internaldate => 1,
      envelope => $json->encode({ Subject => 'old' }) });
    $self->dinsert('imessages', { ifolderid => $ifolderid, uid => 4242, msgid => 'GMnew', thrid => 'Tnew',
      flags => '["\\\\Draft"]', labels => '["\\\\Draft"]', size => 20, internaldate => 2,
      envelope => $json->encode({ Subject => 'new' }) });
    $self->commit();
  };
  my ($msgid, $thrid) = $db->import_message($rfc822, [$drafts], { '$draft' => 1 }, 2);
  is($msgid, 'GMnew', 'import_message: the appended message, not UID 950 of All Mail');
  is($thrid, 'Tnew', 'import_message: in its own thread');

  local *JMAP::ImapDB::backend_cmd = sub { ['append', '[Gmail]/Drafts', 1, 951, undef] };
  local *JMAP::ImapDB::do_folder = sub {};
  ok(!eval { $db->import_message($rfc822, [$drafts], { '$draft' => 1 }, 3); 1 },
     'import_message: with no X-GM-MSGID it fails rather than guess');
}

done_testing();
