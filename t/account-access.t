#!/usr/bin/perl
# A login reaches the accounts in its own pool and no others: the settings
# form, a settings change, detach and delete, and the upload and download
# endpoints all refuse an account in someone else's pool.
#
# _check_account_access once read
#   grep { ... } @{$pool->{accounts}} ? $ok_cb->() : $fail_cb->();
# and grep took the whole ternary as its list, so any login whose pool held
# anything at all -- every one, since it holds the login's own account -- was
# let in to every account.
#
#   bin/restart-test-proxy.sh clean
#   CYRUS_URL=http://localhost:8080 JMAP_PROXY_URL=http://localhost:9000 \
#     JMAP_MGMT_URL=http://localhost:8081 prove -lv t/account-access.t
use strict;
use warnings;
use Test::More;
use JSON::XS;
use HTTP::Tiny;
use MIME::Base64 qw(encode_base64);

unless ($ENV{CYRUS_URL} && $ENV{JMAP_PROXY_URL} && $ENV{JMAP_MGMT_URL}) {
  plan skip_all => "Set CYRUS_URL, JMAP_PROXY_URL and JMAP_MGMT_URL to enable"
}

my $proxy_url = $ENV{JMAP_PROXY_URL} =~ s{/\z}{}r;
my $mgmt_url  = $ENV{JMAP_MGMT_URL}  =~ s{/\z}{}r;
my $pass      = $ENV{CYRUS_PASS} || 'password';
my $imap_host = $ENV{CYRUS_IMAP_HOST} || 'localhost';
my $imap_port = $ENV{CYRUS_IMAP_PORT} || 8143;

my $http = HTTP::Tiny->new(timeout => 60, max_redirect => 0);
my $mgmt = HTTP::Tiny->new(timeout => 120, default_headers => {
  Authorization => 'Bearer ' . ($ENV{JMAP_MGMT_TOKEN} // 'test-mgmt-token-for-the-local-stack') });

my %imap = (imapHost => $imap_host, imapPort => $imap_port, imapSSL => 1,
            smtpHost => $imap_host, smtpPort => 8587, smtpSSL => 1);

eval { require Mail::IMAPClient; 1 }
  or plan skip_all => "Mail::IMAPClient required to provision Cyrus users";
my $admin = Mail::IMAPClient->new(
  Server => $imap_host, Port => $imap_port, Ssl => 0, Uid => 1,
  User => $ENV{CYRUS_ADMIN_USER} || 'admin', Password => $ENV{CYRUS_ADMIN_PASS} || 'admin',
) or plan skip_all => "cannot reach Cyrus IMAP as admin: $@";
# the separator Cyrus reports, not the config's (see CLAUDE.md)
my $sep = $admin->separator || '/';

# two accounts, each in a pool of its own, on fresh empty mailboxes (the
# image's users have whatever earlier runs left, and a first sync of that
# is slow)
my $t = time() . $$;
my %acct = (mine => { aid => "acmine$t", user => "acmine$t" },
            theirs => { aid => "actheirs$t", user => "actheirs$t" });
for my $a (values %acct) {
  $admin->create("user$sep$a->{user}") or die "create $a->{user}: " . $admin->LastError;
  $admin->setacl("user$sep$a->{user}", $a->{user}, "lrswipkxtecdan")
    or die "setacl $a->{user}: " . $admin->LastError;
}
for my $a (values %acct) {
  my $res = $mgmt->post("$mgmt_url/api/accounts", {
    headers => { 'Content-Type' => 'application/json' },
    content => encode_json({ accountid => $a->{aid}, email => "$a->{aid}\@acc.test",
                             username => $a->{user}, password => $pass, %imap }),
  });
  is($res->{status}, 201, "account $a->{aid} made") or diag $res->{content};
  $a->{login} = "$a->{aid}\@acc.test";
}
my $mine   = $acct{mine};
my $theirs = $acct{theirs};

my $as = sub {
  my ($who, $method, $path, $form) = @_;
  my %o = (headers => { Authorization => 'Basic ' . encode_base64("$who->{login}:$pass", '') });
  if ($form) {
    $o{headers}{'Content-Type'} = 'application/x-www-form-urlencoded';
    $o{content} = $http->www_form_urlencode($form);
  }
  return $http->request($method, "$proxy_url$path", \%o);
};

# the caller's own account: let in
is($as->($mine, 'GET', "/accounts/edit?accountid=$mine->{aid}")->{status}, 200,
   'the settings form of my own account');

# someone else's: refused, everywhere
is($as->($mine, 'GET', "/accounts/edit?accountid=$theirs->{aid}")->{status}, 403,
   "not the settings form of another pool's account");
my $res = $as->($mine, 'POST', '/accounts/update',
  { accountid => $theirs->{aid}, username => $mine->{user}, password => $pass, %imap });
is($res->{status}, 403, "not a settings change to it");
is($as->($mine, 'POST', '/accounts/detach', { accountid => $theirs->{aid} })->{status}, 403,
   'not detaching it');
is($as->($mine, 'POST', '/accounts/delete', { accountid => $theirs->{aid} })->{status}, 403,
   'not deleting it');
is($as->($mine, 'GET', "/raw/$theirs->{aid}/Bx/x.eml")->{status}, 403, 'not downloading from it');
$res = $http->request('POST', "$proxy_url/upload/$theirs->{aid}/", {
  headers => { Authorization => 'Basic ' . encode_base64("$mine->{login}:$pass", ''),
               'Content-Type' => 'text/plain' },
  content => 'hello' });
is($res->{status}, 403, 'not uploading to it');

# and it is all still there, as its owner left it
$res = $as->($theirs, 'GET', "/accounts/edit?accountid=$theirs->{aid}");
is($res->{status}, 200, 'the other account is still there');
like($res->{content}, qr/value="\Q$theirs->{user}\E"/, 'with its own login, unchanged');

$mgmt->request('DELETE', "$mgmt_url/api/accounts/$_->{aid}") for values %acct;
for my $a (values %acct) {
  $admin->setacl("user$sep$a->{user}", 'admin', 'lrswipkxtecda');
  $admin->delete("user$sep$a->{user}");
}
done_testing;
