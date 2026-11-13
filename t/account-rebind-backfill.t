#!/usr/bin/perl
#
# Changing an IMAP account's login stops the backfill running under the old one.
#
# A backfill runs in its own "<accountid>:backfill" worker, which keeps the
# IMAP connection it opened.  Settings were replaced by dropping only the
# account's main worker, so a backfill that was running went on, batch after
# batch, through the OLD login.  Switched to another mailbox, the two workers
# fought over INBOX: the new login's sync saw a new UIDVALIDITY and reset the
# folder, the old backfill saw its own and reset it back, and the account
# ended with neither mailbox's mail.  Now both workers are restarted
# (_restart_account) and the backfill starts again under the new login.
#
# An account for a mailbox big enough to need several backfill batches (500
# messages each, ten seconds apart) is switched to a nearly empty mailbox
# while it backfills; once everything has settled, the account must hold only
# the new mailbox's mail.

use strict;
use warnings;
use Test::More;
use JSON::XS;
use HTTP::Tiny;
use MIME::Base64 qw(encode_base64);

unless ($ENV{CYRUS_URL} && $ENV{JMAP_PROXY_URL} && $ENV{JMAP_MGMT_URL}) {
  plan skip_all => "Set CYRUS_URL, JMAP_PROXY_URL and JMAP_MGMT_URL to enable"
    . " (run ./bin/restart-test-proxy.sh clean first, in IMAP mode)";
}

eval { require Mail::IMAPClient; 1 }
  or plan skip_all => "Mail::IMAPClient required to provision Cyrus users";

my $proxy_url = $ENV{JMAP_PROXY_URL} =~ s{/\z}{}r;
my $mgmt_url  = $ENV{JMAP_MGMT_URL}  =~ s{/\z}{}r;
my $pass      = $ENV{CYRUS_PASS} || 'password';
my $imap_host = $ENV{CYRUS_IMAP_HOST} || 'localhost';
my $imap_port = $ENV{CYRUS_IMAP_PORT} || 8143;
my $OLD_COUNT = 2000;

my $t     = time();
my $old   = "rbf-$t-$$-old";
my $new   = "rbf-$t-$$-new";
my $aid   = "rbf$t$$";
my $email = "$old\@example.com";

my $admin = Mail::IMAPClient->new(
  Server => $imap_host, Port => $imap_port, Ssl => 0, Uid => 1,
  User => $ENV{CYRUS_ADMIN_USER} || 'admin', Password => $ENV{CYRUS_ADMIN_PASS} || 'admin',
) or plan skip_all => "cannot reach Cyrus IMAP as admin: $@";
# the separator Cyrus reports, not the config's (see CLAUDE.md)
my $sep = $admin->separator || '/';

my $provision = sub {
  my ($user, $count, $subject) = @_;
  $admin->create("user$sep$user")                       or die "create user$sep$user: " . $admin->LastError;
  $admin->setacl("user$sep$user", $user, "lrswipkxtecdan") or die "setacl $user: " . $admin->LastError;
  my $c = Mail::IMAPClient->new(Server => $imap_host, Port => $imap_port, Ssl => 0, Uid => 1,
                                User => $user, Password => $pass) or die "login $user: $@";
  for my $n (1 .. $count) {
    $c->append_string('INBOX', "From: a\@example.com\r\nTo: $user\@example.com\r\n"
      . "Subject: $subject $n\r\nDate: Thu, 12 Nov 2026 10:00:00 +0000\r\n"
      . "Message-ID: <$subject-$n-$t-$$\@example.com>\r\n\r\nbody $n\r\n")
      or die "append to $user: " . $c->LastError;
  }
  $c->logout;
};
$provision->($old, $OLD_COUNT, 'OLDMAIL');
sleep 2;   # Cyrus's UIDVALIDITY is a timestamp: the two INBOXes must differ
$provision->($new, 3, 'NEWMAIL');

my $http = HTTP::Tiny->new(timeout => 120);
my $mgmt = HTTP::Tiny->new(timeout => 300, default_headers => {
  Authorization => 'Bearer ' . ($ENV{JMAP_MGMT_TOKEN} // 'test-mgmt-token-for-the-local-stack') });

my %imap = (imapHost => $imap_host, imapPort => $imap_port, imapSSL => 1,
            smtpHost => $imap_host, smtpPort => 8587, smtpSSL => 1);

# the account, logged in as $old: firstsync reads 50 messages and the
# backfill loop fetches the rest, 500 at a time
my $res = $mgmt->post("$mgmt_url/api/accounts", {
  headers => { 'Content-Type' => 'application/json' },
  content => encode_json({ accountid => $aid, email => $email, username => $old, password => $pass, %imap }),
});
is($res->{status}, 201, 'account made') or diag $res->{content};

my $jmap = sub {
  my ($calls) = @_;
  my $r = $http->post("$proxy_url/jmap", {
    headers => { 'Content-Type' => 'application/json',
                 Authorization  => 'Basic ' . encode_base64("$email:$pass", '') },
    content => encode_json({ using => ['urn:ietf:params:jmap:core', 'urn:ietf:params:jmap:mail'],
                             methodCalls => $calls }),
  });
  my $d = eval { decode_json($r->{content}) } || {};
  return { map { $_->[2] => $_->[1] } @{ $d->{methodResponses} || [] } };
};
my $count = sub {
  my ($subject) = @_;
  my $r = $jmap->([['Email/query', { accountId => $aid, filter => { subject => $subject },
                                     calculateTotal => JSON::XS::true, limit => 1 }, 'q']]);
  return $r->{q}{total};
};

# a sync, so the account's worker reports the folder to backfill
$jmap->([['Mailbox/get', { accountId => $aid }, 'm']]);

# wait until the backfill is under way: more than firstsync's 50, not all yet
my $started;
for (1 .. 60) {
  my $n = $count->('OLDMAIL') // 0;
  if ($n > 50) { $started = $n; last }
  sleep 1;
}
ok($started && $started < $OLD_COUNT, "the backfill is under way ($started of $OLD_COUNT)")
  or BAIL_OUT("no backfill to interrupt: $started");

# now the same account logs in as $new (the settings form)
$res = $http->post("$proxy_url/accounts/update", {
  headers => { 'Content-Type' => 'application/x-www-form-urlencoded',
               Authorization  => 'Basic ' . encode_base64("$email:$pass", '') },
  content => $http->www_form_urlencode({ accountid => $aid, username => $new, password => $pass, %imap }),
});
ok($res->{status} == 301 || $res->{status} == 302, 'settings replaced') or diag "$res->{status} $res->{content}";

# let any backfill there is run out: three quiet batch intervals in a row
my ($last, $quiet) = (-1, 0);
for (1 .. 40) {
  sleep 5;
  my $now = ($count->('OLDMAIL') // 0) + ($count->('NEWMAIL') // 0) * 100000;
  $quiet = $now == $last ? $quiet + 1 : 0;
  $last = $now;
  last if $quiet >= 6;
}

is($count->('NEWMAIL'), 3, "the account holds the new login's mail");
is($count->('OLDMAIL'), 0, "and none of the old login's: its backfill stopped");

$mgmt->request('DELETE', "$mgmt_url/api/accounts/$aid");
done_testing;
