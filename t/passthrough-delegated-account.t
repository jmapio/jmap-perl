#!/usr/bin/perl
#
# Register a JMAP passthrough account bound to a DELEGATED upstream account.
#
# One Cyrus login (the primary) is granted rights on a second user's mailbox, so
# the primary's JMAP session lists both accountIds.  We then register TWO proxy
# accounts against that one login: the primary (default binding) and the shared
# account (explicit backendAccountId).  Both must exist as distinct proxy
# accounts, each bound to its own upstream account, and each must authenticate.
#
# This is what makes the same-credentials native-forward copy path reachable:
# two distinct proxy accounts sharing one cred_fingerprint.

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
my $primary = "dg-$t-$$-p";
my $shared  = "dg-$t-$$-s";

my $imap = Mail::IMAPClient->new(
  Server => $imap_host, Port => $imap_port, Ssl => 0,
  User => $admin, Password => $admin_pw, Uid => 1,
) or plan skip_all => "cannot reach Cyrus IMAP as admin: $@";

# NOTE: use the separator Cyrus actually reports.  test-config.json says "."
# but Cyrus reports "/" — creating "user.NAME" makes a stray top-level mailbox,
# not a user, and Cyrus then 503s with "Invalid user" on autoprovision.
my $sep = $imap->separator || '/';

for my $u ($primary, $shared) {
  $imap->create("user$sep$u")            or die "create user$sep$u: " . $imap->LastError;
  $imap->setacl("user$sep$u", $u, "lrswipkxtecdan")
    or die "setacl $u: " . $imap->LastError;
}
# Delegate: the primary gets full rights on the shared account.
$imap->setacl("user$sep$shared", $primary, "lrswipkxtecdan")
  or die "delegate: " . $imap->LastError;

my $http = HTTP::Tiny->new(timeout => 30);

# Sanity: the upstream session for the primary must list BOTH accounts.
my $sres = $http->get("$cyrus_url/jmap", {
  headers => { Authorization => 'Basic ' . encode_base64("$primary:$pass", '') },
});
ok($sres->{success}, "fetched upstream Cyrus session as $primary")
  or diag "status $sres->{status}: $sres->{content}";
my $session = $sres->{success} ? decode_json($sres->{content}) : {};
ok($session->{accounts}{$primary}, "upstream session lists the primary account");
ok($session->{accounts}{$shared},
   "upstream session lists the DELEGATED account (needed for this test)")
  or diag "accounts: " . join(', ', sort keys %{ $session->{accounts} || {} });

my $register = sub {
  my (%args) = @_;
  my $res = $http->post("$mgmt_url/api/accounts", {
    headers => { 'Content-Type' => 'application/json' },
    content => encode_json({
      sessionUrl => "$cyrus_url/jmap",
      username   => $primary,          # SAME login for both registrations
      password   => $pass,
      authType   => 'basic',
      %args,
    }),
  });
  return ($res->{status}, eval { decode_json($res->{content}) } || {});
};

# 1. The primary, with no explicit binding — existing behaviour.
my ($st1, $body1) = $register->(accountid => $primary, poolid => $primary);
is($st1, 201, "registered primary passthrough account") or diag encode_json($body1);
is($body1->{accountid}, $primary, "primary got its own proxy accountid");

# 2. The delegated account: same login, explicit backendAccountId.
my ($st2, $body2) = $register->(
  accountid        => $shared,
  poolid           => $primary,
  backendAccountId => $shared,
);
is($st2, 201, "registered delegated passthrough account") or diag encode_json($body2);
isnt($body2->{accountid}, $primary,
     "delegated account is a DISTINCT proxy account, not collapsed into the primary");
is($body2->{accountid}, $shared, "delegated account kept its requested accountid");

# 3. Both accounts exist, each bound to its own upstream account.
my $list = $http->get("$mgmt_url/api/accounts");
my $all  = eval { decode_json($list->{content}) } || [];
my %got  = map { $_->{accountid} => $_ } @$all;
is($got{$primary}{backendAccountId}, $primary,
   "primary is bound to the primary upstream account");
is($got{$shared}{backendAccountId}, $shared,
   "delegated account is bound to the SHARED upstream account");

# 4. Both must authenticate against the proxy.  The delegated account stores the
#    primary's credentials, so auth must not key the credential lookup on email.
for my $who ($primary, $shared) {
  my $r = $http->get("$proxy_url/session", {
    headers => { Authorization => 'Basic ' . encode_base64("$who:$pass", '') },
  });
  ok($r->{success}, "Basic auth to the proxy succeeds as $who")
    or diag "status $r->{status}: " . substr($r->{content} // '', 0, 200);
}

# 5. An explicit accountId reads the delegated account, and a call that OMITS
#    accountId is rejected (invalidArguments, RFC 8620 §3.6.2) rather than
#    forwarded. The upstream's own default for a missing id is the login's
#    PRIMARY account, so forwarding it would silently read the primary's data;
#    the proxy used to paper over that by filling the id in, now it refuses.
{
  my $jmap_as = sub {
    my ($who, @calls) = @_;
    my $r = $http->post("$proxy_url/jmap", {
      headers => { 'Content-Type' => 'application/json',
                   Authorization  => 'Basic ' . encode_base64("$who:$pass", '') },
      content => encode_json({
        using => ['urn:ietf:params:jmap:core', 'urn:ietf:params:jmap:mail'],
        methodCalls => \@calls }),
    });
    return undef unless $r->{success};
    return decode_json($r->{content});
  };
  my $mailbox_names = sub {
    my ($r) = @_;
    my ($resp) = grep { $_->[2] eq 'm' } @{ ($r || {})->{methodResponses} || [] };
    return undef unless $resp && $resp->[0] eq 'Mailbox/get';
    return join(',', sort map { $_->{name} // '' } @{ $resp->[1]{list} || [] });
  };

  # Give the two upstream accounts distinguishable contents.
  $jmap_as->($primary, ['Mailbox/set',
    { accountId => $primary, create => { m => { name => 'MARKER-PRIMARY' } } }, 's']);
  $jmap_as->($shared, ['Mailbox/set',
    { accountId => $shared,  create => { m => { name => 'MARKER-SHARED' } } }, 's']);

  my $explicit = $mailbox_names->($jmap_as->($shared,
    ['Mailbox/get', { accountId => $shared }, 'm']));
  ok($explicit && $explicit =~ /MARKER-SHARED/,
     "explicit accountId reads the delegated account");
  unlike($explicit // '', qr/MARKER-PRIMARY/,
     "explicit accountId does not see the login's primary account");

  my $implicit = $jmap_as->($shared, ['Mailbox/get', {}, 'm']);
  my ($resp) = grep { $_->[2] eq 'm' } @{ ($implicit || {})->{methodResponses} || [] };
  is($resp && $resp->[0], 'error', "omitting accountId is an error, not a default");
  is($resp && $resp->[1]{type}, 'invalidArguments',
     "omitting accountId is invalidArguments");

  # And an accountId that is not one of the session's accounts is accountNotFound.
  my $cross = $jmap_as->($shared, ['Mailbox/get', { accountId => 'no-such-proxy-account' }, 'm']);
  ($resp) = grep { $_->[2] eq 'm' } @{ ($cross || {})->{methodResponses} || [] };
  is($resp && $resp->[1]{type}, 'accountNotFound',
     "an accountId outside the session is accountNotFound");
}

# 6. An explicitly bogus backendAccountId must be rejected, not silently
#    defaulted to the primary.
my ($st3, $body3) = $register->(
  accountid        => "$shared-bogus",
  backendAccountId => 'no-such-account-here',
);
isnt($st3, 201, "registration with an unknown backendAccountId is rejected");

done_testing;
