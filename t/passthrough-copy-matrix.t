#!/usr/bin/perl
#
# Cross-account Email/copy between two passthrough accounts that share ONE
# upstream login (a primary and a delegated account it has rights on).
#
# Because both proxy accounts authenticate to the upstream with the same
# credentials, they share a cred_fingerprint, so the dispatcher forwards the
# copy to the upstream natively instead of orchestrating a blob shuffle.
# The classifier decision itself is unit-covered by t/dispatch-copy-route.t;
# this test proves the path works end to end, which was impossible before the
# proxy could bind an account to a delegated upstream account.
#
# The cross-credential (orchestrated) direction is covered by the
# JMAP-TestSuite's t/Email/copy/basic.t via pool_account_pair.

use strict;
use warnings;
use Test::More;
use JSON::XS;
use HTTP::Tiny;
use MIME::Base64 qw(encode_base64);

unless ($ENV{CYRUS_URL} && $ENV{JMAP_PROXY_URL} && $ENV{JMAP_MGMT_URL}) {
  plan skip_all => "Set CYRUS_URL, JMAP_PROXY_URL and JMAP_MGMT_URL to enable"
    . " (run ./bin/restart-test-proxy.sh --jmap clean first), e.g."
    . " CYRUS_URL=http://localhost:8080 JMAP_PROXY_URL=http://localhost:9000"
    . " JMAP_MGMT_URL=http://localhost:8081";
}

eval { require Mail::IMAPClient; 1 }
  or plan skip_all => "Mail::IMAPClient required to provision Cyrus users";

my $cyrus_url = $ENV{CYRUS_URL}      =~ s{/\z}{}r;
my $proxy_url = $ENV{JMAP_PROXY_URL} =~ s{/\z}{}r;
my $mgmt_url  = $ENV{JMAP_MGMT_URL}  =~ s{/\z}{}r;
my $imap_host = $ENV{CYRUS_IMAP_HOST} || 'localhost';
my $imap_port = $ENV{CYRUS_IMAP_PORT} || 8143;
my $admin     = $ENV{CYRUS_ADMIN_USER} || 'admin';
my $admin_pw  = $ENV{CYRUS_ADMIN_PASS} || 'admin';
my $pass      = $ENV{CYRUS_PASS} || 'password';

my $t       = time();
my $primary = "cm-$t-$$-p";
my $shared  = "cm-$t-$$-s";

my $imap = Mail::IMAPClient->new(
  Server => $imap_host, Port => $imap_port, Ssl => 0,
  User => $admin, Password => $admin_pw, Uid => 1,
) or plan skip_all => "cannot reach Cyrus IMAP as admin: $@";

# Use the separator Cyrus reports, not the one in test-config.json.
my $sep = $imap->separator || '/';
for my $u ($primary, $shared) {
  $imap->create("user$sep$u") or die "create user$sep$u: " . $imap->LastError;
  $imap->setacl("user$sep$u", $u, "lrswipkxtecdan")
    or die "setacl $u: " . $imap->LastError;
}
$imap->setacl("user$sep$shared", $primary, "lrswipkxtecdan")
  or die "delegate: " . $imap->LastError;

my $http = HTTP::Tiny->new(timeout => 60);

# Register both proxy accounts against the SAME upstream login.
for my $spec ([$primary, undef], [$shared, $shared]) {
  my ($aid, $backend) = @$spec;
  my $res = $http->post("$mgmt_url/api/accounts", {
    headers => { 'Content-Type' => 'application/json' },
    content => encode_json({
      accountid  => $aid,
      sessionUrl => "$cyrus_url/jmap",
      username   => $primary,
      password   => $pass,
      authType   => 'basic',
      poolid     => $primary,
      ($backend ? (backendAccountId => $backend) : ()),
    }),
  });
  die "register $aid failed: $res->{status} $res->{content}\n"
    unless $res->{status} == 201;
}

# The dispatcher batches by upstream key, which for a passthrough account is
# "fp:<cred_fingerprint>".  Same fingerprint on both sides is exactly what makes
# the classifier native-forward the copy instead of orchestrating it, so assert
# it directly rather than inferring it from the copy succeeding (an orchestrated
# copy would succeed too).
SKIP: {
  my $datadir = $ENV{JMAP_DATADIR} || '/tmp/jmap-proxy-test';
  my $accounts_db = "$datadir/accounts.sqlite3";
  skip "accounts DB not readable at $accounts_db (set JMAP_DATADIR)", 2
    unless -r $accounts_db;
  eval { require DBI; 1 } or skip "DBI not available", 2;

  my $dbh = DBI->connect("dbi:SQLite:dbname=$accounts_db", undef, undef,
    { AutoCommit => 1, RaiseError => 0, PrintError => 0 })
    or skip "cannot open accounts DB", 2;
  my %fp = map { $_->[0] => $_->[1] } @{
    $dbh->selectall_arrayref(
      "SELECT accountid, cred_fingerprint FROM accounts WHERE accountid IN (?,?)",
      {}, $primary, $shared) || [] };

  ok($fp{$primary}, "primary account has a cred_fingerprint");
  is($fp{$shared}, $fp{$primary},
     "both accounts share one upstream key => copy is native-forwarded, not orchestrated");
}

my $auth = 'Basic ' . encode_base64("$primary:$pass", '');
my $jmap = sub {
  my (@calls) = @_;
  my $res = $http->post("$proxy_url/jmap", {
    headers => { 'Content-Type' => 'application/json', Authorization => $auth },
    content => encode_json({
      using => ['urn:ietf:params:jmap:core', 'urn:ietf:params:jmap:mail'],
      methodCalls => \@calls,
    }),
  });
  die "JMAP request failed: $res->{status} " . substr($res->{content} // '', 0, 300) . "\n"
    unless $res->{success};
  return decode_json($res->{content});
};

# The pool session must expose both accounts to this one login.
my $sres = $http->get("$proxy_url/session", { headers => { Authorization => $auth } });
ok($sres->{success}, "fetched proxy session as $primary")
  or diag "status $sres->{status}: " . substr($sres->{content} // '', 0, 200);
my $session = $sres->{success} ? decode_json($sres->{content}) : {};
ok($session->{accounts}{$primary}, "session lists the primary account");
ok($session->{accounts}{$shared},
   "session lists the delegated account (same login, different upstream account)")
  or diag "accounts: " . join(', ', sort keys %{ $session->{accounts} || {} });

# Find an inbox in each account.
my $inbox_of = sub {
  my ($aid) = @_;
  my $r = $jmap->(['Mailbox/get', { accountId => $aid, ids => undef }, 'm']);
  my ($resp) = grep { $_->[2] eq 'm' } @{ $r->{methodResponses} || [] };
  die "Mailbox/get failed for $aid: " . encode_json($resp // {}) . "\n"
    unless $resp && $resp->[0] eq 'Mailbox/get';
  for my $mbox (@{ $resp->[1]{list} || [] }) {
    return $mbox->{id} if lc($mbox->{name} // '') eq 'inbox'
                       || lc($mbox->{role} // '') eq 'inbox';
  }
  die "no inbox found in $aid\n";
};

my $src_inbox = $inbox_of->($primary);
my $dst_inbox = $inbox_of->($shared);
ok($src_inbox, "found an inbox in the primary account");
ok($dst_inbox, "found an inbox in the delegated account");

# Create a message in the primary account.
my $cres = $jmap->(['Email/set', {
  accountId => $primary,
  create    => { e1 => {
    mailboxIds => { $src_inbox => JSON::XS::true },
    from       => [{ email => "$primary\@example.com" }],
    to         => [{ email => "$shared\@example.com" }],
    subject    => "copy matrix $t",
    bodyValues => { 1 => { value => "native-forward copy test\n" } },
    textBody   => [{ partId => '1', type => 'text/plain' }],
  } },
}, 'c']);
my ($cresp) = grep { $_->[2] eq 'c' } @{ $cres->{methodResponses} || [] };
my $src_id = $cresp && $cresp->[0] eq 'Email/set' ? $cresp->[1]{created}{e1}{id} : undef;
ok($src_id, "created a source email in the primary account")
  or diag explain $cresp;

SKIP: {
  skip "no source email to copy", 3 unless $src_id;

  my $copy = $jmap->(['Email/copy', {
    fromAccountId => $primary,
    accountId     => $shared,
    create        => { c1 => {
      id         => $src_id,
      mailboxIds => { $dst_inbox => JSON::XS::true },
    } },
  }, 'l']);

  my ($resp) = grep { $_->[2] eq 'l' } @{ $copy->{methodResponses} || [] };
  ok($resp, "got a response for the Email/copy call");
  isnt($resp && $resp->[0], 'error', "Email/copy between same-login accounts is not an error")
    or diag explain $resp;

  my $new_id = $resp && $resp->[0] eq 'Email/copy'
             ? $resp->[1]{created}{c1}{id} : undef;
  ok($new_id, "email was copied into the delegated account")
    or diag explain $resp;

  # The copy must really be readable in the destination account.
  if ($new_id) {
    my $g = $jmap->(['Email/get', {
      accountId => $shared, ids => [$new_id], properties => ['subject'],
    }, 'g']);
    my ($gresp) = grep { $_->[2] eq 'g' } @{ $g->{methodResponses} || [] };
    is($gresp && $gresp->[1]{list}[0]{subject}, "copy matrix $t",
       "copied email is readable in the delegated account with the right subject")
      or diag explain $gresp;
  }
}

done_testing;
