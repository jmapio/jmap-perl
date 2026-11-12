#!/usr/bin/perl
#
# Registering a login whose email already has an account re-binds THAT account.
#
# A signup runs in a worker forked under a fresh id. When the email already
# had an account, the signup used to decide on the existing account but then
# store the new credentials in the fresh id's database: an orphan file nothing
# reads, while the existing account went on with its old credentials (a
# Fastmail re-login kept an expired refresh token). Now the signup only probes
# the credentials; __accounts__ decides the account (JMAP::AccountClaim), and
# setup runs in that account's own worker.
#
# Exercised through the management API's passthrough registration, the one
# route that binds on demand: the same email twice, with a different upstream
# login the second time.

use strict;
use warnings;
use Test::More;
use JSON::XS;
use HTTP::Tiny;
use MIME::Base64 qw(encode_base64);

unless ($ENV{CYRUS_URL} && $ENV{JMAP_PROXY_URL} && $ENV{JMAP_MGMT_URL}) {
  plan skip_all => "Set CYRUS_URL, JMAP_PROXY_URL and JMAP_MGMT_URL to enable"
    . " (run ./bin/restart-test-proxy.sh clean first)";
}

eval { require Mail::IMAPClient; 1 }
  or plan skip_all => "Mail::IMAPClient required to provision Cyrus users";

my $cyrus_url = $ENV{CYRUS_URL}      =~ s{/\z}{}r;
my $proxy_url = $ENV{JMAP_PROXY_URL} =~ s{/\z}{}r;
my $mgmt_url  = $ENV{JMAP_MGMT_URL}  =~ s{/\z}{}r;
my $pass      = $ENV{CYRUS_PASS} || 'password';

my $t     = time();
my $user1 = "rb-$t-$$-1";
my $user2 = "rb-$t-$$-2";
my $email = "rb-$t-$$\@example.com";
my $aid1  = "rb$t$$" . 'a';
my $aid2  = "rb$t$$" . 'b';

my $imap = Mail::IMAPClient->new(
  Server => $ENV{CYRUS_IMAP_HOST} || 'localhost', Port => $ENV{CYRUS_IMAP_PORT} || 8143,
  Ssl => 0, Uid => 1,
  User => $ENV{CYRUS_ADMIN_USER} || 'admin', Password => $ENV{CYRUS_ADMIN_PASS} || 'admin',
) or plan skip_all => "cannot reach Cyrus IMAP as admin: $@";
# the separator Cyrus reports, not the config's (see CLAUDE.md)
my $sep = $imap->separator || '/';
for my $u ($user1, $user2) {
  $imap->create("user$sep$u")                    or die "create user$sep$u: " . $imap->LastError;
  $imap->setacl("user$sep$u", $u, "lrswipkxtecdan") or die "setacl $u: " . $imap->LastError;
}

my $http = HTTP::Tiny->new(timeout => 60);
my $mgmt = HTTP::Tiny->new(timeout => 120, default_headers => {
  Authorization => 'Bearer ' . ($ENV{JMAP_MGMT_TOKEN} // 'test-mgmt-token-for-the-local-stack') });

my $register = sub {
  my ($aid, $user) = @_;
  my $res = $mgmt->post("$mgmt_url/api/accounts", {
    headers => { 'Content-Type' => 'application/json' },
    content => encode_json({ accountid => $aid, email => $email, sessionUrl => "$cyrus_url/jmap",
                             username => $user, password => $pass, authType => 'basic' }),
  });
  return ($res->{status}, eval { decode_json($res->{content}) } || { raw => $res->{content} });
};
my $account = sub {
  my ($aid) = @_;
  my $res = $mgmt->get("$mgmt_url/api/accounts/$aid");
  return $res->{status} == 200 ? decode_json($res->{content}) : undef;
};

my ($st, $body) = $register->($aid1, $user1);
is($st, 201, "first registration") or diag explain $body;
is($body->{accountid}, $aid1, "makes $aid1");
is(($account->($aid1) || {})->{username}, $user1, "bound to $user1");

($st, $body) = $register->($aid2, $user2);
is($st, 201, "second registration, same email") or diag explain $body;
is($body->{accountid}, $aid1, "lands on the existing account");
is(($account->($aid1) || {})->{username}, $user2,
   "the existing account now holds the new login");
ok(!$account->($aid2), "no account under the second id");

# And the account really talks to the upstream as the new login: a mailbox
# made directly upstream as $user2 is seen through the proxy.
my $up = $http->post("$cyrus_url/jmap/", {
  headers => { 'Content-Type' => 'application/json',
               Authorization  => 'Basic ' . encode_base64("$user2:$pass", '') },
  content => encode_json({ using => ['urn:ietf:params:jmap:core', 'urn:ietf:params:jmap:mail'],
    methodCalls => [['Mailbox/set', { accountId => $user2, create => { m => { name => 'REBIND-MARK' } } }, 's']] }),
});
ok($up->{success}, "made a marker mailbox upstream as $user2") or diag $up->{content};

my $via = $http->post("$proxy_url/jmap", {
  headers => { 'Content-Type' => 'application/json',
               Authorization  => 'Basic ' . encode_base64("$email:$pass", '') },
  content => encode_json({ using => ['urn:ietf:params:jmap:core', 'urn:ietf:params:jmap:mail'],
    methodCalls => [['Mailbox/get', { accountId => $aid1 }, 'm']] }),
});
my $r = eval { decode_json($via->{content}) } || {};
my ($resp) = grep { $_->[2] eq 'm' } @{ $r->{methodResponses} || [] };
my @names = map { $_->{name} } @{ ($resp && $resp->[1]{list}) || [] };
ok((grep { $_ eq 'REBIND-MARK' } @names), "the proxy account reads ${user2}'s mailboxes")
  or diag "status $via->{status}: " . substr($via->{content} // '', 0, 300);

$mgmt->request('DELETE', "$mgmt_url/api/accounts/$_") for $aid1, $aid2;

done_testing;
