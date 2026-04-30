#!/usr/bin/perl -w

# Single-process JMAP proxy server
# Runs the HTTP frontend in the main process and forks backend workers
# per-account, communicating via socketpairs.

use lib $ENV{JMAP_HOME} || '/home/jmap/jmap-perl';

use strict;
use warnings;
use AnyEvent;
use AnyEvent::HTTPD;
use AnyEvent::Handle;
use AnyEvent::HTTP;
use AnyEvent::Util;
use Cookie::Baker;
use Data::Dumper;
use Data::UUID::LibUUID;
use DBI;
use Digest::SHA qw(sha1_hex sha256);
use Encode qw(encode_utf8);
use File::Temp ();
use HTML::GenerateUtil qw(escape_html escape_uri);
use HTTP::Request;
use HTTP::Response;
use JSON;
use JSON::XS qw(decode_json);
use Crypt::JWT qw(encode_jwt);
use Crypt::PK::RSA;
use MIME::Base64 qw(decode_base64 encode_base64);
use MIME::Base64::URLSafe;
use POSIX qw(:sys_wait_h);
use Socket;
use Template;
use URI;
use JMAP::OAuth::PKCE;
use JMAP::OAuth::Google;
use JMAP::OAuth::Fastmail;
use JMAP::OAuth::PACC;
use JMAP::OAuth::OIDC;

# Backend modules (loaded in child after fork)
# use JMAP::API; use JMAP::ImapDB; etc.

my $BASEURL = $ENV{BASEURL} || 'http://localhost:' . ($ENV{JMAP_PORT} || 9000);
my $jmaphome = $ENV{JMAP_HOME} || '/home/jmap/jmap-perl';
my $datadir = $ENV{JMAP_DATADIR} || '/data';

mkdir "$datadir/tmp" unless -d "$datadir/tmp";

my $TT = Template->new(INCLUDE_PATH => "$jmaphome/htdocs");
my $json = JSON::XS->new->utf8->canonical->pretty();

sub _oidc_rsa_key { JMAP::OAuth::OIDC->rsa_key("$datadir/oidc_key.pem") }

# Short-lived auth codes issued by /oauth/authorize, consumed by /oauth/token.
my %oidc_codes;   # code => { accountid, email, redirect_uri, exp }
my $oidc_cleanup = AnyEvent->timer(interval => 60, cb => sub {
    my $now = time();
    delete $oidc_codes{$_} for grep { $oidc_codes{$_}{exp} < $now } keys %oidc_codes;
});

# Reap zombie children
my $child_watcher = AnyEvent->signal(signal => 'CHLD', cb => sub {
  while ((my $pid = waitpid(-1, WNOHANG)) > 0) {
    warn "Reaped child $pid\n";
  }
});

#
# Backend connection management
#
my %backend;     # name => [AnyEvent::Handle, cmd_counter, pid, last_active]
my %waiting;     # name => { cmd_id => [success_cb, error_cb] }
my %backfilling; # accountid => 1 while prod_backfill loop is active
my %sync_times;  # accountid => unix timestamp of last successful sync

# EventSource (SSE) push connections
# %PushMap: accountid => { conn_id => { write => sub, accountids => [...], close_after => '' } }
my %PushMap;
my $push_conn_counter = 0;

# Send an SSE event to all open connections subscribed to $accountid.
# Cleanup on dead connections is handled inside write_sse itself.
sub PushEvent {
  my ($accountid, $event, $data) = @_;
  $accountid =~ s/:[^:]+$//;
  my $map = $PushMap{$accountid} or return;
  $map->{$_}{write}->($event, $data) for keys %$map;
}
my $start_time = time();

# Prometheus-style counters — incremented in-process, read by /metrics.
my %stat = (
  http_requests        => 0,
  mgmt_requests        => 0,
  jmap_method_calls    => 0,
  backend_errors       => 0,
  auth_cache_hits      => 0,
  auth_cache_misses    => 0,
);

# OAuth2 state: token => { email, auth_aid, provider, code_verifier, token_url,
#   userinfo_url, client_id, client_secret, account_type, imap, expires }
# Populated when user starts OAuth flow, consumed by /cb/oauth callback.
my %oauth_state;
my $oauth_cleanup_timer = AnyEvent->timer(interval => 120, cb => sub {
  my $now = time();
  delete $oauth_state{$_} for grep { $oauth_state{$_}{expires} < $now } keys %oauth_state;
});

sub _base64url     { JMAP::OAuth::PKCE::base64url($_[0]) }
sub _pkce_verifier { JMAP::OAuth::PKCE::verifier() }
sub _pkce_challenge{ JMAP::OAuth::PKCE::challenge($_[0]) }
sub _form_encode    { my %h=@_; my $u=URI->new('http:'); $u->query_form(%h); $u->query // '' }

# Token touch cache: token => [ip, time] — flushed to __accounts__ every 5 min
my %token_touch;
my $TOKEN_TOUCH_INTERVAL = 300;

my $shutting_down = 0;

sub mk_json {
  my $accountid = shift;
  return sub {
    my ($hdl, $res) = @_;
    if ($res->[0] eq 'push') {
      PushEvent($accountid, 'state', { '@type' => 'StateChange', changed => { $accountid => $res->[1] } });
    }
    elsif ($res->[0] eq 'synced') {
      $sync_times{$accountid} = $res->[1];
    }
    elsif ($res->[0] eq 'bye') {
      warn "Backend closing $accountid\n";
      delete $backend{$accountid};
    }
    elsif ($waiting{$accountid}{$res->[2]}) {
      if ($res->[0] eq 'error') {
        $stat{backend_errors}++;
        $waiting{$accountid}{$res->[2]}[1]->($res->[1]);
        warn "Backend error on $accountid: $res->[1]\n";
        delete $backend{$accountid};
      }
      else {
        $backend{$accountid}[3] = time() if $backend{$accountid};
        $waiting{$accountid}{$res->[2]}[0]->($res->[1]);
      }
      delete $waiting{$accountid}{$res->[2]};
      _maybe_finish_shutdown() if $shutting_down;
    }
    else {
      warn "Unexpected response for $accountid: $res->[0]\n";
    }
    $hdl->push_read(json => mk_json($accountid));
  };
}

sub get_backend {
  my $accountid = shift;

  unless ($backend{$accountid}) {
    # Create a socketpair and fork a backend worker
    socketpair(my $parent_sock, my $child_sock, AF_UNIX, SOCK_STREAM, 0)
      or die "socketpair: $!";

    my $pid = fork();
    die "fork: $!" unless defined $pid;

    if ($pid == 0) {
      # Child: run the backend worker
      close $parent_sock;
      $0 = "[jmap proxy] $accountid";

      # Close all other backend handles in the child
      %backend = ();
      %waiting = ();

      eval {
        if ($accountid ne '__accounts__') {
          require IO::Socket::SSL;
          require JMAP::API;
          require JMAP::ImapDB;
          require JMAP::DB;
        }
        run_backend_worker($child_sock, $accountid);
      };
      warn "Backend worker $accountid died: $@" if $@;
      exit 0;
    }

    # Parent: set up AnyEvent handle on our end
    close $child_sock;
    $parent_sock->blocking(0);

    $backend{$accountid} = [AnyEvent::Handle->new(
      fh => $parent_sock,
      on_error => sub {
        warn "Backend handle error for $accountid\n";
        delete $backend{$accountid};
      },
      on_eof => sub {
        warn "Backend handle EOF for $accountid\n";
        delete $backend{$accountid};
      },
    ), 0, $pid, time()];

    $backend{$accountid}[0]->push_read(json => mk_json($accountid));
  }

  return $backend{$accountid};
}

sub _make_json_io {
  my ($sock) = @_;
  my $jenc = JSON::XS->new->utf8->canonical;
  my $buf = '';

  my $read_json = sub {
    while (1) {
      my $obj = eval { $jenc->incr_parse($buf) };
      if ($obj) {
        $buf = $jenc->incr_text // '';
        $jenc->incr_reset;
        return $obj;
      }
      my $n = sysread($sock, $buf, 65536, length($buf));
      return undef unless $n;
    }
  };

  my $write_json = sub {
    my $data = $jenc->encode($_[0]) . "\n";
    my $off = 0;
    while ($off < length($data)) {
      my $n = syswrite($sock, $data, length($data) - $off, $off);
      die "write failed: $!" unless defined $n;
      $off += $n;
    }
  };

  return ($read_json, $write_json);
}

sub run_backend_worker {
  my ($sock, $name) = @_;

  if ($name eq '__accounts__') {
    return run_accounts_worker($sock);
  }

  # Strip worker-type suffix: "$accountid:backfill" shares account data
  # but MUST run in a separate process from the jmap/sync worker.
  # RULE: backfill and sync/jmap MUST NEVER share a worker process.
  my $accountid = $name;
  $accountid =~ s/:[^:]+$//;
  $0 = "[jmap worker] $name";

  my ($read_json, $write_json) = _make_json_io($sock);

  # Load the account database — may not exist yet (signup creates it)
  my $dbh = DBI->connect("dbi:SQLite:dbname=$datadir/accounts.sqlite3");
  my ($email, $type) = $dbh->selectrow_array(
    "SELECT email, type FROM accounts WHERE accountid = ?", {}, $accountid);

  my ($db, $api);
  my $init_db = sub {
    return if $db;
    ($email, $type) = $dbh->selectrow_array(
      "SELECT email, type FROM accounts WHERE accountid = ?", {}, $accountid)
      unless $type;
    die "No such account: $accountid\n" unless $type;
    if ($type eq 'imap') {
      $db = JMAP::ImapDB->new($accountid);
      $api = JMAP::API->new($db);
      $db->{change_cb} = sub {
        my ($db, $states) = @_;
        eval { $write_json->(['push', $states, 'state']) };
      };
    } elsif ($type eq 'jmap') {
      require JMAP::JmapDB;
      $db = JMAP::JmapDB->new($accountid);
      # No $api — JMAP passthrough bypasses the local API layer entirely
    } elsif ($type eq 'gmail') {
      require JMAP::GmailDB;
      $db = JMAP::GmailDB->new($accountid);
      $api = JMAP::API->new($db);
      $db->{change_cb} = sub {
        my ($db, $states) = @_;
        eval { $write_json->(['push', $states, 'state']) };
      };
    } elsif ($type eq 'fastmail') {
      require JMAP::FastmailDB;
      $db = JMAP::FastmailDB->new($accountid);
      $api = JMAP::API->new($db);
      $db->{change_cb} = sub {
        my ($db, $states) = @_;
        eval { $write_json->(['push', $states, 'state']) };
      };
    } else {
      die "Unsupported account type: $type\n";
    }
  };

  # Initialize now if account exists, otherwise defer to signup/setup
  eval { $init_db->() } if $type;

  my $last_activity = time();

  # Simple blocking request loop
  while (my $request = $read_json->()) {
    my ($cmd, $args, $tag) = @$request;
    my $t0 = [Time::HiRes::gettimeofday()];

    my $res = eval {
      if ($cmd eq 'ping') {
        return ['pong', $accountid];
      }
      if ($cmd eq 'getinfo') {
        return ['info', [$email, $type]];
      }

      # Initialize DB for commands that need it (not signup/signup_jmap — they create the account first)
      $init_db->() if $cmd ne 'signup' && $cmd ne 'signup_jmap' && !$db;

      # Defensive: clean up stale transactions between commands
      if ($db && $db->in_transaction()) {
        warn "WORKER STALE TRANSACTION before $cmd ($tag) - rolling back\n";
        $db->reset();
      }

      if ($cmd eq 'signup') {
        require Net::DNS;
        require Mail::IMAPTalk;

        my $detail = { %$args };
        my $force = delete $detail->{force};
        $detail->{imapPort} ||= 993;
        $detail->{imapSSL} ||= 2;
        $detail->{smtpPort} ||= 587;
        $detail->{smtpSSL} ||= 3;

        # Well-known providers
        if ($detail->{username} =~ m/\@icloud\.com/) {
          $detail->{imapHost} = 'imap.mail.me.com';
          $detail->{smtpHost} = 'smtp.mail.me.com';
          $detail->{caldavURL} = 'https://caldav.icloud.com/';
          $detail->{carddavURL} = 'https://contacts.icloud.com/';
          $force = 1;
        }
        elsif ($detail->{username} =~ m/\@yahoo\.com/) {
          $detail->{imapHost} = 'imap.mail.yahoo.com';
          $detail->{smtpHost} = 'smtp.mail.yahoo.com';
          $detail->{caldavURL} = 'https://caldav.calendar.yahoo.com';
          $detail->{carddavURL} = 'https://carddav.address.yahoo.com';
          $force = 1;
        }
        my $resolver = Net::DNS::Resolver->new;
        my $domain = $detail->{username};
        $domain =~ s/.*\@//;

        my $srv_lookup = sub {
          my ($name) = @_;
          my $reply = $resolver->query($name, 'SRV') or return ();
          return grep { $_->type eq 'SRV' && $_->target ne '.' && $_->port > 0 } $reply->answer;
        };

        unless ($detail->{imapHost}) {
          for my $try (['_imaps._tcp', 'imapHost', 'imapPort', 2],
                       ['_imap._tcp',  'imapHost', 'imapPort', 3]) {
            my @d = $srv_lookup->("$try->[0].$domain");
            if (@d) {
              $detail->{$try->[1]} = $d[0]->target;
              $detail->{$try->[2]} = $d[0]->port;
              $detail->{imapSSL} = $try->[3];
              last;
            }
          }
          for my $try (['_submissions._tcp', 'smtpHost', 'smtpPort', 2],
                       ['_smtps._tcp',       'smtpHost', 'smtpPort', 2],
                       ['_submission._tcp',   'smtpHost', 'smtpPort', 3]) {
            my @d = $srv_lookup->("$try->[0].$domain");
            if (@d) {
              $detail->{$try->[1]} = $d[0]->target;
              $detail->{$try->[2]} = $d[0]->port;
              $detail->{smtpSSL} = $try->[3];
              last;
            }
          }
        }

        # Always look up CalDAV/CardDAV via SRV if not already provided
        # (Mozilla autoconfig doesn't include DAV URLs)
        for my $try (['_caldavs._tcp',  'caldavURL',  'https', 443],
                     ['_caldav._tcp',   'caldavURL',  'http',  80 ],
                     ['_carddavs._tcp', 'carddavURL', 'https', 443],
                     ['_carddav._tcp',  'carddavURL', 'http',  80 ]) {
          next if $detail->{$try->[1]};
          my @d = $srv_lookup->("$try->[0].$domain");
          if (@d) {
            my $url = "$try->[2]://" . $d[0]->target;
            $url .= ":" . $d[0]->port unless $d[0]->port == $try->[3];
            $detail->{$try->[1]} = $url;
          }
        }

        unless ($force) {
          return ['signup', ['continue', $detail]];
        }

        # Test IMAP login
        my $imap = Mail::IMAPTalk->new(
          Server => $detail->{imapHost},
          Port => $detail->{imapPort},
          UseSSL => ($detail->{imapSSL} > 1),
          UseBlocking => ($detail->{imapSSL} > 1),
        );
        die "Cannot connect to IMAP server $detail->{imapHost}:$detail->{imapPort}\n" unless $imap;

        my $ok = $imap->login($detail->{username}, $detail->{password});
        die "Login failed for $detail->{username}\n" unless $ok;
        $imap->logout();

        # Create account in accounts DB
        my $existing_aid = $dbh->selectrow_array(
          "SELECT accountid FROM accounts WHERE email = ?", {}, $detail->{username});
        my $final_aid;
        if ($existing_aid) {
          $final_aid = $existing_aid;
          # Join pool if requested
          if ($detail->{poolid}) {
            $dbh->do("UPDATE accounts SET poolid = ? WHERE accountid = ?",
              {}, $detail->{poolid}, $existing_aid);
          }
        } else {
          $final_aid = $accountid;
          my $poolid = $detail->{poolid} || $accountid;
          $dbh->do("INSERT INTO accounts (email, accountid, type, poolid) VALUES (?, ?, ?, ?)",
            {}, $detail->{username}, $accountid, 'imap', $poolid);
        }

        # Initialize DB now that the account exists
        $type = 'imap';
        $init_db->();

        # Set up the account
        $db->setuser($detail);
        $db->firstsync();

        return ['signup', ['done', $final_aid, $detail->{username}]];
      }
      if ($cmd eq 'signup_oauth') {
        # Called after parent completes OAuth code exchange.
        # $args: email, refresh_token, account_type (gmail/imap), imapHost, imapPort,
        #        imapSSL, smtpHost, smtpPort, smtpSSL, caldavURL, carddavURL, poolid
        my $email         = $args->{email}         or die "email required\n";
        my $refresh_token = $args->{refresh_token} or die "refresh_token required\n";
        my $acct_type     = $args->{account_type}  || 'gmail';

        my $existing_aid = $dbh->selectrow_array(
          "SELECT accountid FROM accounts WHERE email = ?", {}, $email);
        my ($final_aid, $target_aid);
        if ($existing_aid) {
          $final_aid  = $existing_aid;
          $target_aid = $existing_aid;
          if ($args->{poolid}) {
            $dbh->do("UPDATE accounts SET poolid = ? WHERE accountid = ?",
              {}, $args->{poolid}, $existing_aid);
          }
        } else {
          $final_aid  = $accountid;
          $target_aid = $accountid;
          my $poolid = $args->{poolid} || $accountid;
          $dbh->do(
            "INSERT INTO accounts (email, accountid, type, poolid) VALUES (?,?,?,?)",
            {}, $email, $accountid, $acct_type, $poolid);
        }

        # Create/open the per-account DB for the right account ID
        my $target_db;
        if ($acct_type eq 'gmail') {
          require JMAP::GmailDB;
          $target_db = JMAP::GmailDB->new($target_aid);
        } elsif ($acct_type eq 'fastmail') {
          require JMAP::FastmailDB;
          $target_db = JMAP::FastmailDB->new($target_aid);
        } else {
          require JMAP::ImapDB;
          $target_db = JMAP::ImapDB->new($target_aid);
        }
        $target_db->setuser({
          username   => $email,
          password   => $refresh_token,
          imapHost   => $args->{imapHost}   || '',
          imapPort   => $args->{imapPort}   || 993,
          imapSSL    => $args->{imapSSL}    // 1,
          smtpHost   => $args->{smtpHost}   || '',
          smtpPort   => $args->{smtpPort}   || 587,
          smtpSSL    => $args->{smtpSSL}    // 1,
          caldavURL  => $args->{caldavURL}  || '',
          carddavURL => $args->{carddavURL} || '',
        });
        $target_db->firstsync();

        # Make $db point to the right instance for subsequent commands
        if ($target_aid eq $accountid) {
          $type = $acct_type;
          $db   = $target_db;
          $api  = JMAP::API->new($db);
        }

        return ['signup_oauth', [$final_aid, $email]];
      }
      if ($cmd eq 'signup_jmap') {
        require JMAP::JmapDB;
        require MIME::Base64;

        # Verify credentials by fetching the upstream JMAP session
        my $tmp = JMAP::JmapDB->new($accountid);
        my ($session) = $tmp->fetch_session($args);

        # Resolve URLs relative to the session URL (some servers return relative paths).
        # Do NOT use URI->new_abs here — it percent-encodes URI template variables like {accountId}.
        # Instead: if the URL is already absolute, keep it; otherwise prepend the origin.
        my ($session_origin) = ($args->{sessionUrl} =~ m{^(https?://[^/]+)});
        my $abs_url = sub {
            my $url = shift // '';
            return $url if !$url || $url =~ m{^https?://};
            return "$session_origin$url";  # absolute path (starts with /)
        };

        my $api_url = $session->{apiUrl}
          or die "No apiUrl in upstream JMAP session\n";
        $api_url = $abs_url->($api_url);

        # Find the primary mail accountId on the upstream server
        my $mail_cap   = 'urn:ietf:params:jmap:mail';
        my $backend_aid = $session->{primaryAccounts}{$mail_cap}
          or die "No primary mail account in upstream JMAP session\n";
        my $capabilities = $session->{accounts}{$backend_aid} || {};
        my $display_email = $args->{username} || $backend_aid;

        # Create the account entry in accounts.sqlite3
        my $existing_aid = $dbh->selectrow_array(
          "SELECT accountid FROM accounts WHERE email = ?", {}, $display_email);
        my $final_aid;
        if ($existing_aid) {
          $final_aid = $existing_aid;
          if ($args->{poolid}) {
            $dbh->do("UPDATE accounts SET poolid = ? WHERE accountid = ?",
              {}, $args->{poolid}, $existing_aid);
          }
        } else {
          $final_aid = $accountid;
          my $poolid = $args->{poolid} || $accountid;
          $dbh->do(
            "INSERT INTO accounts (email, accountid, type, poolid, needs_backfill)
             VALUES (?,?,?,?,?)",
            {}, $display_email, $accountid, 'jmap', $poolid, 0);
        }

        # Initialise JmapDB and store credentials
        $type = 'jmap';
        $init_db->();

        $db->setuser({
          username         => $args->{username} // '',
          password         => $args->{password} // '',
          authType         => $args->{authType} || 'basic',
          sessionUrl       => $args->{sessionUrl},
          apiUrl           => $api_url,
          uploadUrl        => $abs_url->($session->{uploadUrl}   // ''),
          downloadUrl      => $abs_url->($session->{downloadUrl} // ''),
          backendAccountId => $backend_aid,
          capabilities     => $capabilities,
        });

        return ['signup_jmap', [$final_aid, $display_email]];
      }
      if ($cmd eq 'setup') {
        $db->setuser({
          username   => $args->{username}   || $accountid,
          password   => $args->{password}   || '',
          imapHost   => $args->{imapHost},
          imapPort   => $args->{imapPort}   || 993,
          imapSSL    => $args->{imapSSL}    // 0,
          smtpHost   => $args->{smtpHost}   || $args->{imapHost},
          smtpPort   => $args->{smtpPort}   || 587,
          smtpSSL    => $args->{smtpSSL}    // 0,
          caldavURL  => $args->{caldavURL}  || '',
          carddavURL => $args->{carddavURL} || '',
        });
        $db->firstsync();
        $db->sync_imap();
        return ['setup', $JSON::true];
      }
      if ($cmd eq 'upload') {
        my ($aid, $utype, $file) = @{$args}{qw(accountId type file)};
        if ($db->can('proxy_upload')) {
          my $r = $db->proxy_upload($utype, $file);
          unlink $file;
          return ['upload', $r];
        }
        my ($r) = $api->uploadFile($aid || $accountid, $utype, { file => $file });
        return ['upload', $r];
      }
      if ($cmd eq 'download') {
        if ($db->can('proxy_blob')) {
          my ($dtype, $content) = $db->proxy_blob(
            $args->{blobId}, $args->{name}, $args->{type});
          return ['download', [$dtype, $content]];
        }
        my ($dtype, $content) = $api->downloadFile($args->{blobId});
        return ['download', [$dtype, $content]];
      }
      if ($cmd eq 'raw') {
        my $selector = "$args->{blobId}/$args->{name}";
        my ($rtype, $content, $filename) = $api->getRawBlob($selector);
        return ['raw', [$rtype, $content, $filename]];
      }
      if ($cmd eq 'jmap') {
        my $result;
        if ($db->can('handle_jmap')) {
          # JMAP passthrough — forward directly to upstream, rewriting accountIds
          $result = $db->handle_jmap($args);
        } else {
          $result = $api->handle_request($args);
        }
        # Add sessionState: checksum of sorted accountIds in pool (RFC 8620)
        my $poolid = $dbh->selectrow_array(
          "SELECT poolid FROM accounts WHERE accountid = ?", {}, $accountid) || $accountid;
        my $aids = $dbh->selectcol_arrayref(
          "SELECT accountid FROM accounts WHERE poolid = ? ORDER BY accountid", {}, $poolid);
        $result->{sessionState} = Digest::SHA::sha1_hex(join(',', @$aids));
        return ['jmap', $result];
      }
      if ($cmd eq 'sync') {
        # JMAP passthrough accounts have no local sync
        return ['sync', $JSON::true] if $db->can('handle_jmap');
        $db->sync_folders();
        $db->sync_imap();
        $db->sync_calendars();
        $db->sync_addressbooks();
        eval { $write_json->(['synced', time()]) };
        return ['sync', $JSON::true];
      }
      # IMPORTANT: 'backfill' MUST only be sent to "$accountid:backfill" workers,
      # never to the jmap/sync worker. See prod_backfill() in the parent.
      if ($cmd eq 'backfill') {
        # JMAP passthrough accounts have no backfill
        return ['backfill', 0] if $db->can('handle_jmap');
        my $more = $db->backfill() ? 1 : 0;
        return ['backfill', $more];
      }
      if ($cmd eq 'davsync') {
        $db->sync_calendars();
        $db->sync_addressbooks();
        return ['davsync', $JSON::true];
      }
      if ($cmd eq 'get_settings') {
        my $data;
        if ($db->can('handle_jmap')) {
          $data = $db->access_data();  # includes type='jmap'
        } else {
          $db->begin();
          $data = $db->dgetone('iserver') || {};
          $db->commit();
          $data->{type} = 'imap';
        }
        delete $data->{password};
        return ['get_settings', $data];
      }
      if ($cmd eq 'update_settings') {
        if ($db->can('handle_jmap')) {
          # Verify new JMAP credentials then update stored settings
          my ($session) = $db->fetch_session($args);
          my $mail_cap  = 'urn:ietf:params:jmap:mail';
          my $backend_aid = $session->{primaryAccounts}{$mail_cap}
            or die "No primary mail account in upstream JMAP session\n";
          $db->setuser({
            username         => $args->{username} // '',
            password         => $args->{password} // '',
            authType         => $args->{authType} || 'basic',
            sessionUrl       => $args->{sessionUrl},
            apiUrl           => $session->{apiUrl},
            backendAccountId => $backend_aid,
            capabilities     => $session->{accounts}{$backend_aid} || {},
          });
          return ['update_settings', $JSON::true];
        }
        require Mail::IMAPTalk;
        my $host = $args->{imapHost} or die "imapHost required\n";
        my $port = $args->{imapPort} || 993;
        my $ssl  = $args->{imapSSL} // 2;
        my $imap = Mail::IMAPTalk->new(
          Server      => $host,
          Port        => $port,
          UseSSL      => ($ssl > 1),
          UseBlocking => ($ssl > 1),
        );
        die "Cannot connect to IMAP server $host:$port\n" unless $imap;
        my $ok = $imap->login($args->{username}, $args->{password});
        die "Login failed for $args->{username}\n" unless $ok;
        $imap->logout();
        $db->setuser($args);
        return ['update_settings', $JSON::true];
      }
      if ($cmd eq 'delete') {
        $db->delete() if $db;
        return ['deleted', $JSON::true];
      }
      die "Unknown command: $cmd\n";
    };
    unless ($res) {
      my $err = "$@";
      eval { $db->rollback() } if $db && $db->in_transaction();
      warn "ERROR $cmd ($tag) ($accountid): $err\n";
      $write_json->(['error', $err, $tag]);
      last;  # die on error — parent will spawn fresh child
    }
    $res->[2] = $tag;
    $write_json->($res);

    my $elapsed = Time::HiRes::tv_interval($t0);
    warn "HANDLED $cmd ($tag) => ($accountid) in $elapsed\n";

    $last_activity = time();

    # Exit after 'delete' command
    last if $cmd eq 'delete';
  }
}

my $ACCOUNTS_SCHEMA_VERSION = 1;

sub _migrate_accounts_db {
  my ($dbh) = @_;
  my ($v) = $dbh->selectrow_array('PRAGMA user_version');

  if ($v == 0) {
    # Fresh install — create full schema at version 1 (the baseline; no migration needed).
    $dbh->begin_work;
    eval {
      $dbh->do("CREATE TABLE accounts (email TEXT PRIMARY KEY, accountid TEXT, type TEXT, poolid TEXT, needs_backfill INTEGER NOT NULL DEFAULT 1)");
      $dbh->do("CREATE TABLE tokens (token TEXT PRIMARY KEY, accountid TEXT NOT NULL, last_used INTEGER, last_ip TEXT)");
      $dbh->do("PRAGMA user_version = $ACCOUNTS_SCHEMA_VERSION");
      $dbh->commit;
    };
    if ($@) { $dbh->rollback; die "accounts DB init failed: $@" }
    warn "accounts.sqlite3: created at schema version $ACCOUNTS_SCHEMA_VERSION\n";
    return;
  }

  # Incremental migrations — each in its own transaction, version bumped atomically.
  # To add version 2: add a block here:
  #   if ($v < 2) {
  #     $dbh->begin_work;
  #     eval { ... ALTER TABLE ...; $dbh->do('PRAGMA user_version = 2'); $dbh->commit };
  #     if ($@) { $dbh->rollback; die "migration to v2 failed: $@" }
  #     warn "accounts.sqlite3: migrated to schema version 2\n";
  #     $v = 2;
  #   }
  # Then bump $ACCOUNTS_SCHEMA_VERSION above.
}

sub run_accounts_worker {
  my ($sock) = @_;

  $0 = "[jmap accounts]";

  my ($read_json, $write_json) = _make_json_io($sock);

  my $dbh = DBI->connect("dbi:SQLite:dbname=$datadir/accounts.sqlite3");
  _migrate_accounts_db($dbh);

  while (my $request = $read_json->()) {
    my ($cmd, $args, $tag) = @$request;
    my $t0 = [Time::HiRes::gettimeofday()];

    my $res = eval {
      if ($cmd eq 'ping') {
        return ['pong', '__accounts__'];
      }

      if ($cmd eq 'list_accounts') {
        my $rows = $dbh->selectall_arrayref(
          "SELECT email, accountid, type FROM accounts ORDER BY accountid",
          { Slice => {} });
        for my $row (@$rows) {
          my $details = _account_details_child($row->{accountid});
          $row->{$_} = $details->{$_} for keys %$details;
        }
        return ['list_accounts', $rows];
      }

      if ($cmd eq 'get_account') {
        my $aid = $args->{accountid};
        my $row = $dbh->selectrow_hashref(
          "SELECT email, accountid, type FROM accounts WHERE accountid = ?",
          {}, $aid);
        return ['get_account', undef] unless $row;
        my $details = _account_details_child($aid);
        $row->{$_} = $details->{$_} for keys %$details;
        return ['get_account', $row];
      }

      if ($cmd eq 'create_account') {
        my $aid = $args->{accountid};
        my $type = $args->{type} || 'imap';
        my $email = $args->{email} || $aid;
        my $poolid = $args->{poolid} || $aid;
        $dbh->do("INSERT OR REPLACE INTO accounts (email, accountid, type, poolid, needs_backfill) VALUES (?, ?, ?, ?, 1)",
          {}, $email, $aid, $type, $poolid);
        return ['create_account', { accountid => $aid, type => $type, poolid => $poolid }];
      }

      if ($cmd eq 'get_pool') {
        my $aid = $args->{accountid};
        my $row = $dbh->selectrow_hashref(
          "SELECT poolid FROM accounts WHERE accountid = ?", {}, $aid);
        return ['get_pool', { accounts => [] }] unless $row;
        my $poolid = $row->{poolid};
        my $rows = $dbh->selectall_arrayref(
          "SELECT email, accountid, type FROM accounts WHERE poolid = ? ORDER BY accountid",
          { Slice => {} }, $poolid);
        for my $r (@$rows) {
          my $details = _account_details_child($r->{accountid});
          $r->{$_} = $details->{$_} for keys %$details;
        }
        return ['get_pool', { poolid => $poolid, accounts => $rows }];
      }

      if ($cmd eq 'set_poolid') {
        my $aid = $args->{accountid};
        my $poolid = $args->{poolid};
        $dbh->do("UPDATE accounts SET poolid = ? WHERE accountid = ?", {}, $poolid, $aid);
        return ['set_poolid', { accountid => $aid, poolid => $poolid }];
      }

      if ($cmd eq 'create_token') {
        my $token = $args->{token};
        my $aid = $args->{accountid};
        my $ip = $args->{last_ip};
        my $ts = $args->{last_used} || time();
        $dbh->do("INSERT OR REPLACE INTO tokens (token, accountid, last_used, last_ip) VALUES (?, ?, ?, ?)",
          {}, $token, $aid, $ts, $ip);
        return ['create_token', { token => $token, accountid => $aid }];
      }

      if ($cmd eq 'resolve_token') {
        my $token = $args->{token};
        my $row = $dbh->selectrow_hashref(
          "SELECT accountid FROM tokens WHERE token = ?", {}, $token);
        return ['resolve_token', $row ? $row->{accountid} : undef];
      }

      if ($cmd eq 'touch_tokens') {
        # Batch update last_used/last_ip for a set of tokens
        # args: { tokens => [ [token, ip, time], ... ] }
        my $sth = $dbh->prepare(
          "UPDATE tokens SET last_used = ?, last_ip = ? WHERE token = ?");
        for my $entry (@{$args->{tokens}}) {
          my ($token, $ip, $ts) = @$entry;
          $sth->execute($ts, $ip, $token);
        }
        return ['touch_tokens', { count => scalar @{$args->{tokens}} }];
      }

      if ($cmd eq 'list_tokens') {
        # List all tokens for accounts in the given pool
        my $poolid = $args->{poolid};
        my $rows = $dbh->selectall_arrayref(
          "SELECT t.token, t.accountid, t.last_used, t.last_ip
           FROM tokens t
           JOIN accounts a ON a.accountid = t.accountid
           WHERE a.poolid = ?
           ORDER BY t.last_used DESC NULLS LAST",
          { Slice => {} }, $poolid);
        return ['list_tokens', $rows || []];
      }

      if ($cmd eq 'delete_token') {
        my $token = $args->{token};
        $dbh->do("DELETE FROM tokens WHERE token = ?", {}, $token);
        return ['delete_token', { ok => 1 }];
      }

      if ($cmd eq 'auth') {
        # Authenticate by email + password: look up account, check stored password
        my $email = $args->{username};
        my $password = $args->{password};
        my $row = $dbh->selectrow_hashref(
          "SELECT accountid, poolid FROM accounts WHERE email = ?", {}, $email);
        return ['auth', undef] unless $row;

        # Check password against per-account DB (credentials in iserver table)
        my $aid = $row->{accountid};
        my $dbfile = "$datadir/$aid.sqlite3";
        return ['auth', undef] unless -f $dbfile;
        my $udb = DBI->connect("dbi:SQLite:dbname=$dbfile");
        my $stored = $udb->selectrow_hashref(
          "SELECT password FROM iserver WHERE username = ?", {}, $email);
        return ['auth', undef] unless $stored && $stored->{password} eq $password;

        # Create a token for this session
        my $token = _generate_token();
        $dbh->do("INSERT INTO tokens (token, accountid) VALUES (?, ?)", {}, $token, $aid);

        # Get all accounts in the pool
        my $poolid = $row->{poolid} || $aid;
        my $pool = $dbh->selectall_arrayref(
          "SELECT email, accountid, type FROM accounts WHERE poolid = ? ORDER BY accountid",
          { Slice => {} }, $poolid);

        return ['auth', { accountid => $aid, poolid => $poolid, email => $email,
                          token => $token, accounts => $pool }];
      }

      if ($cmd eq 'verify_credentials') {
        my $email = $args->{username};
        my $password = $args->{password};
        my $row = $dbh->selectrow_hashref(
          "SELECT accountid, type FROM accounts WHERE email = ?", {}, $email);
        return ['verify_credentials', undef] unless $row;
        my $aid = $row->{accountid};
        # OAuth accounts have no stored password to compare against
        return ['verify_credentials', undef]
          if ($row->{type} // '') eq 'gmail' || ($row->{type} // '') eq 'fastmail';
        my $dbfile = "$datadir/$aid.sqlite3";
        return ['verify_credentials', undef] unless -f $dbfile;
        my $udb = DBI->connect("dbi:SQLite:dbname=$dbfile");
        my $stored = $udb->selectrow_hashref(
          "SELECT password FROM iserver WHERE username = ?", {}, $email);
        return ['verify_credentials', undef] unless $stored;
        require JMAP::CredentialStore;
        my $actual = JMAP::CredentialStore->decrypt($stored->{password});
        return ['verify_credentials', undef] unless $actual eq $password;
        return ['verify_credentials', { accountid => $aid }];
      }

      if ($cmd eq 'get_needs_backfill') {
        my $rows = $dbh->selectcol_arrayref(
          "SELECT accountid FROM accounts WHERE needs_backfill = 1");
        return ['get_needs_backfill', $rows || []];
      }

      if ($cmd eq 'clear_backfill') {
        my $aid = $args->{accountid};
        $dbh->do("UPDATE accounts SET needs_backfill = 0 WHERE accountid = ?", {}, $aid);
        return ['clear_backfill', { accountid => $aid }];
      }

      if ($cmd eq 'delete_account') {
        my $aid = $args->{accountid};
        # Find the pool this account belongs to
        my ($poolid) = $dbh->selectrow_array(
          "SELECT poolid FROM accounts WHERE accountid = ?", {}, $aid);
        # Remove the account
        $dbh->do("DELETE FROM accounts WHERE accountid = ?", {}, $aid);
        # If this account was the poolid, re-pool siblings under themselves
        if ($poolid && $poolid eq $aid) {
          my $siblings = $dbh->selectcol_arrayref(
            "SELECT accountid FROM accounts WHERE poolid = ?", {}, $aid);
          for my $sib (@$siblings) {
            $dbh->do("UPDATE accounts SET poolid = ? WHERE accountid = ?", {}, $sib, $sib);
          }
        }
        # Delete tokens that now point to a non-existent account
        $dbh->do("DELETE FROM tokens WHERE accountid NOT IN (SELECT accountid FROM accounts)");
        unlink "$datadir/$aid.sqlite3";
        unlink "$datadir/$aid.lock";
        return ['delete_account', { deleted => $aid }];
      }

      die "Unknown accounts command: $cmd\n";
    };
    unless ($res) {
      my $err = "$@";
      warn "ERROR accounts $cmd ($tag): $err\n";
      $write_json->(['error', $err, $tag]);
      next;  # accounts worker stays alive on error
    }
    $res->[2] = $tag;
    $write_json->($res);

    my $elapsed = Time::HiRes::tv_interval($t0);
    warn "HANDLED accounts $cmd ($tag) in $elapsed\n";
  }
}

sub _account_details_child {
  my ($accountid) = @_;
  my $dbfile = "$datadir/$accountid.sqlite3";
  return {} unless -f $dbfile;
  my $udb = eval { DBI->connect("dbi:SQLite:dbname=$dbfile") };
  return {} unless $udb;
  my $iserver = eval { $udb->selectrow_hashref("SELECT * FROM iserver LIMIT 1") } || {};
  my ($folders) = eval { $udb->selectrow_array("SELECT COUNT(*) FROM ifolders") } // 0;
  my ($messages) = eval { $udb->selectrow_array("SELECT COUNT(*) FROM jmessages WHERE active = 1") } // 0;
  return {
    configured => (defined $iserver->{username} ? 1 : 0),
    username   => $iserver->{username},
    imapHost   => $iserver->{imapHost},
    imapPort   => $iserver->{imapPort},
    caldavURL  => $iserver->{caldavURL},
    carddavURL => $iserver->{carddavURL},
    folders    => $folders,
    messages   => $messages,
  };
}

sub send_backend_request {
  my $accountid = shift;
  my $request = shift;
  my $args = shift;
  my $cb = shift;
  my $errcb = shift;
  my $backend = get_backend($accountid);
  my $cmd = "#" . $backend->[1]++;
  $backend->[3] = time();
  $waiting{$accountid}{$cmd} = [$cb || sub { 1 }, $errcb || sub { 1 }];
  $backend->[0]->push_write(json => [$request, $args, $cmd]);
}

#
# HTTP handlers (from server.pl)
#

sub invalid_request {
  my $req = shift;
  $req->respond([400, 'invalid request', {}, 'invalid request']);
}

sub not_found {
  my $req = shift;
  $req->respond([404, 'not found', {}, 'not found']);
}

sub do_wellknown {
  my ($httpd, $req) = @_;
  my $path = $req->url->path;
  if ($path eq '/.well-known/jmap') {
    $req->respond([301, 'redirected', { Location => "$BASEURL/session" }, "Redirected"]);
    return;
  }
  if ($path eq '/.well-known/openid-configuration') {
    my $cfg = encode_json({
      issuer                                => $BASEURL,
      authorization_endpoint                => "$BASEURL/oauth/authorize",
      token_endpoint                        => "$BASEURL/oauth/token",
      userinfo_endpoint                     => "$BASEURL/oauth/userinfo",
      jwks_uri                              => "$BASEURL/oauth/jwks",
      scopes_supported                      => ['openid', 'email', 'profile'],
      response_types_supported              => ['code'],
      grant_types_supported                 => ['authorization_code', 'refresh_token'],
      subject_types_supported               => ['public'],
      id_token_signing_alg_values_supported => ['RS256'],
      token_endpoint_auth_methods_supported => ['none'],
      code_challenge_methods_supported      => ['S256'],
    });
    $req->respond({ content => ['application/json', $cfg] });
    return;
  }
  if ($path eq '/.well-known/webfinger') {
    # Tell tmail-web that the OIDC issuer is our own BASEURL
    my $resource = $req->url->query_param('resource') // '';
    my $body = encode_json({
      subject => $resource,
      links   => [{
        rel  => 'http://openid.net/specs/connect/1.0/issuer',
        href => $BASEURL,
      }],
    });
    $req->respond({ content => ['application/jrd+json', $body] });
    return;
  }
  not_found($req);
}

sub do_session {
  my ($httpd, $req) = @_;

  $httpd->stop_request();
  _authenticate($req, $httpd, sub {
    my ($auth_aid) = @_;
    # Get pool info for this account
    send_backend_request('__accounts__', 'get_pool', { accountid => $auth_aid }, sub {
      my $pool = shift;
      my $accounts = {};
      my ($primary_aid, $primary_cal_aid, $primary_contact_aid);
      for my $a (@{$pool->{accounts} || []}) {
        $accounts->{$a->{accountid}} = {
          name => $a->{email} || $a->{accountid},
          isPersonal => JSON::true,
          isReadOnly => JSON::false,
          accountCapabilities => {
            'urn:ietf:params:jmap:mail' => {
              maxMailboxesPerEmail         => undef,
              maxMailboxDepth              => undef,
              maxSizeMailboxName           => 490,
              maxSizeAttachmentsPerEmail   => 50_000_000,
              emailQuerySortOptions        => [qw(
                receivedAt sentAt size subject from to id
                hasKeyword allInThreadHaveKeyword someInThreadHaveKeyword
              )],
              mayCreateTopLevelMailbox     => JSON::true,
            },
            'urn:ietf:params:jmap:submission' => {
              maxDelayedSend => 0,
            },
            'urn:ietf:params:jmap:mdn'   => {},
            'urn:ietf:params:jmap:quota' => {},
            ($a->{caldavURL}  ? ('urn:ietf:params:jmap:calendars' => {
              maxCalendarsPerEvent     => undef,
              minDateTime              => '1970-01-01T00:00:00Z',
              maxDateTime              => '2099-12-31T23:59:59Z',
              maxExpandedQueryDuration => 'P2Y',
              maxParticipantsPerEvent  => undef,
              mayCreateCalendar        => JSON::true,
            }) : ()),
            ($a->{carddavURL} ? ('urn:ietf:params:jmap:contacts' => {
              maxAddressBooksPerCard => undef,
              mayCreateAddressBook   => JSON::true,
            }) : ()),
          },
        };
        $primary_aid         //= $a->{accountid};
        $primary_cal_aid     //= $a->{accountid} if $a->{caldavURL};
        $primary_contact_aid //= $a->{accountid} if $a->{carddavURL};
      }
      $primary_aid //= $auth_aid;

      my $session = {
        capabilities => {
          'urn:ietf:params:jmap:core' => {
            maxSizeUpload => 50_000_000,
            maxConcurrentUpload => 4,
            maxSizeRequest => 10_000_000,
            maxConcurrentRequests => 4,
            maxCallsInRequest => 16,
            maxObjectsInGet => 4096,
            maxObjectsInSet => 4096,
            collationAlgorithms => [],
          },
          'urn:ietf:params:jmap:mail' => {},
          'urn:ietf:params:jmap:submission' => {},
          'urn:ietf:params:jmap:mdn'   => {},
          'urn:ietf:params:jmap:quota' => {},
          'urn:ietf:params:jmap:calendars' => {
            maxCalendarsPerEvent     => undef,
            minDateTime              => '1970-01-01T00:00:00Z',
            maxDateTime              => '2099-12-31T23:59:59Z',
            maxExpandedQueryDuration => 'P2Y',
            maxParticipantsPerEvent  => undef,
            mayCreateCalendar        => JSON::true,
          },
          'urn:ietf:params:jmap:contacts' => {
            maxAddressBooksPerCard => undef,
            mayCreateAddressBook   => JSON::true,
          },
        },
        accounts => $accounts,
        primaryAccounts => {
          'urn:ietf:params:jmap:mail'       => $primary_aid,
          'urn:ietf:params:jmap:submission' => $primary_aid,
          ($primary_cal_aid     ? ('urn:ietf:params:jmap:calendars' => $primary_cal_aid)     : ()),
          ($primary_contact_aid ? ('urn:ietf:params:jmap:contacts'  => $primary_contact_aid) : ()),
        },
        username => ($pool->{accounts} && $pool->{accounts}[0] ? $pool->{accounts}[0]{email} : ''),
        apiUrl => "$BASEURL/jmap",
        downloadUrl => "$BASEURL/raw/{accountId}/{blobId}/{name}",
        uploadUrl => "$BASEURL/upload/{accountId}",
        eventSourceUrl => "$BASEURL/eventsource?types={types}&closeafter={closeafter}&ping={ping}",
        state => sha1_hex(join(',', sort map { $_->{accountid} } @{$pool->{accounts} || []})),
      };

      warn "SESSION " . JSON::XS::encode_json($session) . "\n";
      $req->respond([200, 'ok', { 'Content-Type' => 'application/json' },
        JSON::XS::encode_json($session)]);
    }, sub {
      my $err = shift;
      $req->respond([500, 'error', { 'Content-Type' => 'application/json' },
        JSON::XS::encode_json({ type => 'serverError', message => "$err" })]);
    });
  }, sub {
    _require_auth($req);
  });
}

my %KNOWN_CAPABILITIES = map { $_ => 1 } qw(
  urn:ietf:params:jmap:core
  urn:ietf:params:jmap:mail
  urn:ietf:params:jmap:submission
  urn:ietf:params:jmap:mdn
  urn:ietf:params:jmap:quota
  urn:ietf:params:jmap:calendars
  urn:ietf:params:jmap:contacts
);

sub _jmap_request_error {
  my ($req, $type, $detail) = @_;
  $req->respond([400, 'bad request', {'Content-Type' => 'application/json'},
    $json->encode({ type => "urn:ietf:params:jmap:error:$type", status => 400, detail => $detail })]);
}

sub do_jmap {
  my ($httpd, $req) = @_;

  my $path = $req->url->path;

  unless (lc $req->method eq 'post') {
    return _jmap_request_error($req, 'notRequest', 'JMAP endpoint requires POST.');
  }

  my $content = $req->content;
  my $data = eval { decode_json($content) };
  if ($@) {
    return _jmap_request_error($req, 'notJSON', 'The content of the request is not valid JSON.');
  }
  unless (ref $data eq 'HASH' && ref $data->{methodCalls} eq 'ARRAY' && ref $data->{using} eq 'ARRAY') {
    return _jmap_request_error($req, 'notRequest', 'The content of the request is not a valid JMAP Request object.');
  }

  for my $cap (@{$data->{using}}) {
    unless ($KNOWN_CAPABILITIES{$cap}) {
      return _jmap_request_error($req, 'unknownCapability', "The capability $cap is not supported.");
    }
  }

  if ($path eq '/jmap' || $path eq '/jmap/') {
    $httpd->stop_request();
    _authenticate($req, $httpd, sub {
      my ($auth_aid) = @_;
      _do_jmap_request($req, $auth_aid, $data);
    }, sub {
      _require_auth($req);
    });
    return;
  }

  invalid_request($req);
}

sub _do_jmap_request {
  my ($req, $accountid, $data) = @_;
  my @methods = map { $_->[0] } @{$data->{methodCalls} || []};
  $stat{jmap_method_calls} += scalar @methods;
  warn "JMAP REQUEST ($accountid): " . join(', ', @methods) . "\n";
  warn "JMAP REQUEST BODY: " . $json->encode($data) . "\n" if $ENV{JMAP_DEBUG};
  send_backend_request($accountid, 'jmap', $data, sub {
    my $result = shift;
    my $body = $json->encode($result);
    warn "JMAP RESPONSE: " . length($body) . " bytes\n";
    warn "JMAP RESPONSE BODY: $body\n" if $ENV{JMAP_DEBUG};
    $req->respond([200, 'ok', { 'Content-Type' => 'application/json' }, $body]);
  }, sub {
    my $error = shift;
    $req->respond({
      content => ['application/json', $json->encode({
        methodResponses => [['error', { type => 'serverError', message => "$error" }, 'a']],
      })],
    });
  });
}

sub do_upload {
  my ($httpd, $req) = @_;

  my $path = $req->url->path;
  return invalid_request($req) unless $path =~ m{^/upload/([^/]+)/?$};
  my $accountid = $1;
  return invalid_request($req) unless lc $req->method eq 'post';

  my $type    = $req->headers->{'content-type'} || 'application/octet-stream';
  my $content = $req->content;

  # Write upload content to tempfile to avoid passing binary through JSON socketpair
  my $tmp = File::Temp->new(DIR => "$datadir/tmp", UNLINK => 0);
  print $tmp $content;
  close $tmp;
  my $tmpfile = $tmp->filename;

  $httpd->stop_request();
  _authenticate($req, $httpd, sub {
    my ($auth_aid) = @_;
    _check_account_access($auth_aid, $accountid, sub {
      send_backend_request($accountid, 'upload', { accountId => $accountid, type => $type, file => $tmpfile }, sub {
        my $result = shift;
        $req->respond({ content => ['application/json', $json->encode($result)] });
      }, sub {
        unlink $tmpfile;
        $req->respond([500, 'error', {}, 'upload failed']);
      });
    }, sub {
      unlink $tmpfile;
      $req->respond([403, 'forbidden', {}, 'Forbidden']);
    });
  }, sub {
    unlink $tmpfile;
    _require_auth($req);
  });
}

sub do_raw {
  my ($httpd, $req) = @_;

  my $path = $req->url->path;
  return invalid_request($req) unless $path =~ m{^/raw/([^/]+)/([^/]+)/(.+)$};
  my ($accountid, $blobid, $name) = ($1, $2, $3);
  my $type = $req->url->query_param('type') // '';

  $httpd->stop_request();
  _authenticate($req, $httpd, sub {
    my ($auth_aid) = @_;
    _check_account_access($auth_aid, $accountid, sub {
      send_backend_request($accountid, 'download', { blobId => $blobid, name => $name, type => $type }, sub {
        my $result = shift;
        my $ct = $result->[0] || 'application/octet-stream';
        (my $enc_name = $name) =~ s/([^\w.\-])/sprintf('%%%02X', ord($1))/ge;
        $req->respond([200, 'ok', {
          'Content-Type'        => $ct,
          'Content-Disposition' => "attachment; filename*=UTF-8''$enc_name",
          'Cache-Control'       => 'private, immutable, max-age=31536000',
        }, $result->[1]]);
      }, sub {
        $req->respond([404, 'not found', {}, 'not found']);
      });
    }, sub {
      $req->respond([403, 'forbidden', {}, 'Forbidden']);
    });
  }, sub {
    _require_auth($req);
  });
}

sub do_landing {
  my ($httpd, $req) = @_;
  $httpd->stop_request();
  _try_authenticate($req, $httpd, sub {
    my ($auth_aid) = @_;
    if ($auth_aid) {
      return $req->respond([301, 'redirected', { Location => "$BASEURL/accounts" }, "Redirected"]);
    }
    my $html = '';
    $TT->process("index.html", { baseurl => $BASEURL }, \$html)
      || return $req->respond([500, 'error', {}, $Template::ERROR]);
    $req->respond({ content => ['text/html', $html] });
  });
}

sub do_static {
  my ($httpd, $req) = @_;
  my $path = $req->url->path;
  $path =~ s{^/}{};
  return not_found($req) unless $path =~ /\.(css|js|html|png|ico|svg)$/;
  my $file = $path =~ m{^assets/} ? "$jmaphome/$path" : "$jmaphome/htdocs/$path";
  return not_found($req) unless -f $file;
  my %types = (css => 'text/css', js => 'text/javascript', html => 'text/html',
               png => 'image/png', ico => 'image/x-icon', svg => 'image/svg+xml');
  my ($ext) = $path =~ /\.(\w+)$/;
  open my $fh, '<', $file or return not_found($req);
  local $/;
  my $content = <$fh>;
  close $fh;
  $req->respond([200, 'ok', { 'Content-Type' => $types{$ext} || 'application/octet-stream',
                              'Cache-Control' => 'max-age=86400' }, $content]);
}

sub _generate_token {
  open my $fh, '<', '/dev/urandom' or die "Cannot open /dev/urandom: $!";
  my $bytes;
  read $fh, $bytes, 32;  # 256 bits
  close $fh;
  return unpack('H*', $bytes);
}

sub _time_ago {
  my ($ts) = @_;
  return 'never' unless $ts;
  my $diff = time() - $ts;
  return 'just now'               if $diff < 60;
  return int($diff/60)   . ' minutes ago' if $diff < 3600;
  return int($diff/3600) . ' hours ago'   if $diff < 86400;
  return int($diff/86400). ' days ago';
}

sub _get_auth_accountid {
  my ($req) = @_;
  # Cookie contains a token, not an accountid — check the cache
  my $cookies = crush_cookie($req->headers->{cookie} || '');
  my $token = $cookies->{jmap_proxy};
  return undef unless $token;
  my $cached = _check_cache("bearer:$token");
  return $cached;
  # Note: if not cached, caller must use _authenticate() for async resolution
}

# Cache auth results: key => [accountid, expire_time]
my %auth_cache;
my $AUTH_CACHE_TTL = 300;  # 5 minutes

# Checks that $auth_aid has pool access to $accountid, then calls $ok_cb or $fail_cb.
sub _check_account_access {
  my ($auth_aid, $accountid, $ok_cb, $fail_cb) = @_;
  if ($auth_aid eq $accountid) { $ok_cb->(); return; }
  send_backend_request('__accounts__', 'get_pool', { accountid => $auth_aid }, sub {
    my $pool = shift;
    grep { $_->{accountid} eq $accountid } @{$pool->{accounts} || []}
      ? $ok_cb->() : $fail_cb->();
  }, sub { $fail_cb->() });
}

# Like _authenticate but cookie-only, never errors — calls $cb->(undef) if not logged in.
sub _try_authenticate {
  my ($req, $httpd, $cb) = @_;
  my $cookies = crush_cookie($req->headers->{cookie} || '');
  my $token = $cookies->{jmap_proxy};
  unless ($token) { $cb->(undef); return; }
  my $cached = _check_cache("bearer:$token");
  if ($cached) { $cb->($cached); return; }
  $httpd->stop_request();
  send_backend_request('__accounts__', 'resolve_token', { token => $token }, sub {
    my $aid = shift;
    $auth_cache{"bearer:$token"} = [$aid, time() + $AUTH_CACHE_TTL] if $aid;
    $cb->($aid);
  }, sub { $cb->(undef) });
}

sub _check_cache {
  my ($key) = @_;
  if (my $cached = $auth_cache{$key}) {
    if ($cached->[1] > time()) {
      $stat{auth_cache_hits}++;
      return $cached->[0];
    }
    delete $auth_cache{$key};
  }
  $stat{auth_cache_misses}++;
  return undef;
}

sub _client_ip {
  my ($req) = @_;
  my $xff = $req->headers->{'x-forwarded-for'};
  return (split /\s*,\s*/, $xff)[0] if $xff;
  return $req->client_host;
}

sub _touch_token {
  my ($token, $ip) = @_;
  $token_touch{$token} = [$ip, time()];
}

# Authenticate via Basic auth, Bearer token, or cookie.
# All are async since token/Basic resolution goes through __accounts__ child.
# Calls $cb->($accountid) on success, $errcb->() on failure.
sub _authenticate {
  my ($req, $httpd, $cb, $errcb) = @_;
  my $auth_header = $req->headers->{authorization} || '';

  # Bearer token — resolve to accountid
  if ($auth_header =~ /^Bearer\s+(\S+)$/i) {
    my $token = $1;
    my $ip = _client_ip($req);
    my $cached = _check_cache("bearer:$token");
    if ($cached) { _touch_token($token, $ip); $cb->($cached); return; }
    $httpd->stop_request();
    send_backend_request('__accounts__', 'resolve_token', { token => $token }, sub {
      my $aid = shift;
      if ($aid) {
        $auth_cache{"bearer:$token"} = [$aid, time() + $AUTH_CACHE_TTL];
        _touch_token($token, $ip);
        $cb->($aid);
      } else {
        $errcb->();
      }
    }, sub { $errcb->() });
    return;
  }

  # Cookie — token in cookie, resolve to accountid
  my $cookies = crush_cookie($req->headers->{cookie} || '');
  if (my $token = $cookies->{jmap_proxy}) {
    my $ip = _client_ip($req);
    my $cached = _check_cache("bearer:$token");
    if ($cached) { _touch_token($token, $ip); $cb->($cached); return; }
    $httpd->stop_request();
    send_backend_request('__accounts__', 'resolve_token', { token => $token }, sub {
      my $aid = shift;
      if ($aid) {
        $auth_cache{"bearer:$token"} = [$aid, time() + $AUTH_CACHE_TTL];
        _touch_token($token, $ip);
        $cb->($aid);
      } else {
        $errcb->();
      }
    }, sub { $errcb->() });
    return;
  }

  # Basic auth — verify password, get accountid
  if ($auth_header =~ /^Basic\s+(\S+)$/i) {
    my $b64 = $1;
    my $cached = _check_cache("basic:$b64");
    if ($cached) { $cb->($cached); return; }

    my $decoded = eval { decode_base64($b64) };
    if ($decoded && $decoded =~ /^([^:]+):(.+)$/) {
      my ($user, $pass) = ($1, $2);
      $httpd->stop_request();
      send_backend_request('__accounts__', 'auth', { username => $user, password => $pass }, sub {
        my $result = shift;
        if ($result && $result->{accountid}) {
          $auth_cache{"basic:$b64"} = [$result->{accountid}, time() + $AUTH_CACHE_TTL];
          $cb->($result->{accountid});
        } else {
          $errcb->();
        }
      }, sub { $errcb->() });
      return;
    }
  }

  $errcb->();
}

sub _require_auth {
  my ($req) = @_;
  $req->respond([401, 'unauthorized',
    { 'Content-Type' => 'application/json', 'WWW-Authenticate' => 'Basic realm="JMAP Proxy"' },
    '{"type":"unauthorized"}']);
}

# Render the "step 2" password form (or error) back on index.html.
# $prefill hashref may contain imapHost/imapPort/imapSSL/smtpHost/smtpPort/caldavURL/carddavURL/force.
sub _render_step2 {
  my ($req, $email, $error, $prefill) = @_;
  my $html = '';
  $TT->process("index.html", {
    baseurl => $BASEURL,
    step    => 2,
    email   => $email,
    error   => $error,
    prefill => $prefill || {},
  }, \$html) || return $req->respond([500, 'error', {}, $Template::ERROR]);
  $req->respond([200, 'ok', { 'Content-Type' => 'text/html; charset=utf-8' }, $html]);
}

sub _start_google_oauth {
  my ($email, $auth_aid) = @_;
  my $state_token = _generate_token();
  my ($url, $state) = JMAP::OAuth::Google->auth_url_and_state(
    email         => $email,
    auth_aid      => $auth_aid,
    baseurl       => $BASEURL,
    state_token   => $state_token,
    client_id     => $ENV{GOOGLE_CLIENT_ID},
    client_secret => $ENV{GOOGLE_CLIENT_SECRET},
  );
  $oauth_state{$state_token} = $state;
  return $url;
}

my $fastmail_client_id;  # cached from dynamic client registration

sub _do_fastmail_redirect {
  my ($client_id, $email, $auth_aid, $req, $via) = @_;
  my $state_token = _generate_token();
  my $verifier    = _pkce_verifier();
  my ($url, $state) = JMAP::OAuth::Fastmail->auth_url_and_state(
    client_id     => $client_id,
    email         => $email,
    auth_aid      => $auth_aid,
    baseurl       => $BASEURL,
    state_token   => $state_token,
    code_verifier => $verifier,
    challenge     => _pkce_challenge($verifier),
    via           => $via,
  );
  $oauth_state{$state_token} = $state;
  $req->respond([302, 'Found', { Location => $url }, '']);
}

sub _start_fastmail_oauth {
  my ($email, $auth_aid, $req, $via) = @_;
  my $client_id = $ENV{FASTMAIL_CLIENT_ID} || $fastmail_client_id;
  if ($client_id) {
    _do_fastmail_redirect($client_id, $email, $auth_aid, $req, $via);
    return;
  }
  # Dynamic client registration (async — parent event loop)
  my $err_html = sub {
    my ($msg) = @_;
    my $html = '';
    $TT->process("index.html", { baseurl => $BASEURL, error => $msg }, \$html);
    $req->respond([500, 'error', { 'Content-Type' => 'text/html' }, $html]);
  };
  AnyEvent::HTTP::http_request('POST', JMAP::OAuth::Fastmail::REG_URL,
    headers => { 'Content-Type' => 'application/json' },
    body    => JMAP::OAuth::Fastmail->registration_body("$BASEURL/cb/oauth"),
    timeout => 10,
    sub {
      my ($rbody, $hdrs) = @_;
      unless (($hdrs->{Status} // 0) =~ /^2/) {
        return $err_html->("Fastmail client registration failed ($hdrs->{Status}). Please try again.");
      }
      my $data = eval { decode_json($rbody) };
      unless ($data && $data->{client_id}) {
        return $err_html->("Fastmail registration returned no client_id. Please try again.");
      }
      $fastmail_client_id = $data->{client_id};
      _do_fastmail_redirect($fastmail_client_id, $email, $auth_aid, $req, $via);
    }
  );
}

sub _start_pacc_oauth {
  my ($meta, $email, $auth_aid, $req, $prefill, $client_id, $client_secret) = @_;
  my $state_token = _generate_token();
  my $verifier    = _pkce_verifier();
  my ($url, $state) = JMAP::OAuth::PACC->auth_url_and_state(
    meta          => $meta,
    email         => $email,
    auth_aid      => $auth_aid,
    baseurl       => $BASEURL,
    state_token   => $state_token,
    code_verifier => $verifier,
    challenge     => _pkce_challenge($verifier),
    prefill       => $prefill,
    client_id     => $client_id,
    client_secret => $client_secret,
  );
  $oauth_state{$state_token} = $state;
  $req->respond([302, 'Found', { Location => $url }, '']);
}

# Try PACC, then Mozilla autoconfig, then fall back to step-2 password form.
sub _discover_fallback {
  my ($domain, $email, $auth_aid, $req) = @_;

  my $pacc_url = "https://ua-auto-config.$domain/.well-known/user-agent-configuration.json";
  AnyEvent::HTTP::http_get($pacc_url, timeout => 5,
    headers => { Accept => 'application/json' },
    sub {
      my ($body, $hdrs) = @_;
      if (($hdrs->{Status} // 0) == 200) {
        my $cfg = eval { decode_json($body) };
        if ($cfg) {
          # Extract protocol pre-fills
          my %prefill;
          if (my $imap = $cfg->{protocols}{imap}) {
            $prefill{imapHost} = $imap->{host} if $imap->{host};
            $prefill{imapPort} = $imap->{port} if $imap->{port};
          }
          if (my $smtp = $cfg->{protocols}{smtp}) {
            $prefill{smtpHost} = $smtp->{host} if $smtp->{host};
            $prefill{smtpPort} = $smtp->{port} if $smtp->{port};
          }
          $prefill{caldavURL}  = $cfg->{protocols}{caldav}{url}  if $cfg->{protocols}{caldav}{url};
          $prefill{carddavURL} = $cfg->{protocols}{carddav}{url} if $cfg->{protocols}{carddav}{url};
          $prefill{force}      = 1 if $prefill{imapHost};

          # If PACC also has a JMAP endpoint, go straight to JMAP passthrough signup
          if (my $jmap_url = $cfg->{protocols}{jmap}{url}) {
            my $html = '';
            $TT->process("index.html", {
              baseurl    => $BASEURL,
              step       => 'jmap',
              email      => $email,
              jmap_url   => $jmap_url,
            }, \$html) || return $req->respond([500, 'error', {}, $Template::ERROR]);
            return $req->respond([200, 'ok', { 'Content-Type' => 'text/html; charset=utf-8' }, $html]);
          }

          # If PACC advertises OAuth, fetch RFC 8414 metadata
          if (my $issuer = $cfg->{authentication}{'oauth-public'}{issuer}) {
            my $meta_url = "${issuer}/.well-known/oauth-authorization-server";
            AnyEvent::HTTP::http_get($meta_url, timeout => 5,
              headers => { Accept => 'application/json' },
              sub {
                my ($mbody, $mhdrs) = @_;
                my $meta = (($mhdrs->{Status} // 0) == 200) ? eval { decode_json($mbody) } : undef;
                if ($meta && $meta->{authorization_endpoint} && $meta->{token_endpoint}) {
                  # Look for per-domain OAuth credentials in env
                  # Env var pattern: OAUTH_EXAMPLE_COM_CLIENT_ID (domain uppercased, dots→_)
                  (my $env_key = uc $domain) =~ s/[^A-Z0-9]/_/g;
                  my $cid  = $ENV{"OAUTH_${env_key}_CLIENT_ID"};
                  my $csec = $ENV{"OAUTH_${env_key}_CLIENT_SECRET"};
                  if ($cid && $csec) {
                    _start_pacc_oauth($meta, $email, $auth_aid, $req, \%prefill, $cid, $csec);
                    return;
                  }
                }
                # OAuth configured but we lack client credentials — or metadata fetch failed
                _render_step2($req, $email, undef, \%prefill);
              });
            return;
          }

          # PACC found, no OAuth — pre-fill and show password form
          _render_step2($req, $email, undef, \%prefill);
          return;
        }
      }

      # PACC failed — try Mozilla autoconfig
      _try_mozilla_autoconfig($domain, $email, $auth_aid, $req);
    });
}

sub _try_mozilla_autoconfig {
  my ($domain, $email, $auth_aid, $req) = @_;
  my $url = "https://autoconfig.$domain/mail/config-v1.1.xml";
  AnyEvent::HTTP::http_get($url, timeout => 5, sub {
    my ($body, $hdrs) = @_;
    my %prefill;
    if (($hdrs->{Status} // 0) == 200 && $body) {
      # Extract IMAP settings
      if ($body =~ m{<incomingServer\s+type="imap"[^>]*>(.*?)</incomingServer>}s) {
        my $s = $1;
        $prefill{imapHost} = $1 if $s =~ m{<hostname>(.*?)</hostname>};
        $prefill{imapPort} = $1 if $s =~ m{<port>(.*?)</port>};
        if ($s =~ m{<socketType>(.*?)</socketType>}) {
          $prefill{imapSSL} = ($1 eq 'SSL') ? 2 : (($1 eq 'STARTTLS') ? 3 : 1);
        }
      }
      if ($body =~ m{<outgoingServer\s+type="smtp"[^>]*>(.*?)</outgoingServer>}s) {
        my $s = $1;
        $prefill{smtpHost} = $1 if $s =~ m{<hostname>(.*?)</hostname>};
        $prefill{smtpPort} = $1 if $s =~ m{<port>(.*?)</port>};
        if ($s =~ m{<socketType>(.*?)</socketType>}) {
          $prefill{smtpSSL} = ($1 eq 'SSL') ? 2 : (($1 eq 'STARTTLS') ? 3 : 1);
        }
      }
      $prefill{force} = 1 if $prefill{imapHost};
    }
    _render_step2($req, $email, undef, \%prefill);
  });
}

# POST /discover — email-only submission; does discovery and either redirects to
# OAuth or renders the step-2 password form.
sub do_discover {
  my ($httpd, $req) = @_;
  return invalid_request($req) unless lc $req->method eq 'post';

  my $email = $req->parm('username') // '';
  my $via   = $req->parm('via')      // '';
  $email =~ s/^\s+|\s+$//g;
  my (undef, $domain) = split /\@/, $email, 2;
  return invalid_request($req) unless $domain;
  $domain = lc $domain;

  $httpd->stop_request();

  _try_authenticate($req, $httpd, sub {
    my ($auth_aid) = @_;

    # Known provider: Google
    if ($domain =~ /^(gmail|googlemail)\.com$/) {
      if ($ENV{GOOGLE_CLIENT_ID} && $ENV{GOOGLE_CLIENT_SECRET}) {
        $req->respond([302, 'Found', { Location => _start_google_oauth($email, $auth_aid) }, '']);
      } else {
        _render_step2($req, $email,
          'Gmail requires OAuth2. Set GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET to enable it.', {});
      }
      return;
    }

    # Known provider: Fastmail.
    # Offer a choice: native JMAP passthrough (password) or IMAP/OAuth.
    # If the user already chose IMAP (via=imap), skip the choice and start OAuth.
    if ($domain =~ /^(fastmail\.(com|fm|net|org|to|cn|es|de|in|us)|messagingengine\.com)$/) {
      if ($via eq 'imap' || $via eq 'jmap') {
        _start_fastmail_oauth($email, $auth_aid, $req, $via);
      } else {
        my $html = '';
        $TT->process("index.html", {
          baseurl  => $BASEURL,
          step     => 'choose',
          email    => $email,
          jmap_url => 'https://api.fastmail.com/jmap/session',
        }, \$html) || return $req->respond([500, 'error', {}, $Template::ERROR]);
        $req->respond([200, 'ok', { 'Content-Type' => 'text/html; charset=utf-8' }, $html]);
      }
      return;
    }

    # Everything else: PACC → autoconfig → password form
    _discover_fallback($domain, $email, $auth_aid, $req);
  });
}

# GET /cb/oauth — OAuth2 callback (handles all providers via %oauth_state lookup)
sub do_cb_oauth {
  my ($httpd, $req) = @_;

  my $state_token = $req->parm('state') // '';
  my $code        = $req->parm('code')  // '';
  my $oauth_error = $req->parm('error') // '';

  if ($oauth_error) {
    my $html = '';
    $TT->process("index.html", { baseurl => $BASEURL,
      error => "OAuth authorization failed: $oauth_error" }, \$html);
    return $req->respond([200, 'ok', { 'Content-Type' => 'text/html' }, $html]);
  }

  my $state = $oauth_state{$state_token};
  unless ($state) {
    my $html = '';
    $TT->process("index.html", { baseurl => $BASEURL,
      error => "OAuth session expired or invalid. Please try again." }, \$html);
    return $req->respond([400, 'bad request', { 'Content-Type' => 'text/html' }, $html]);
  }
  delete $oauth_state{$state_token};

  $httpd->stop_request();

  # Exchange authorization code for tokens
  my $form_body = _form_encode(
    client_id    => $state->{client_id},
    redirect_uri => "$BASEURL/cb/oauth",
    code         => $code,
    grant_type   => 'authorization_code',
    ($state->{client_secret} ? (client_secret => $state->{client_secret}) : ()),
    ($state->{code_verifier} ? (code_verifier => $state->{code_verifier}) : ()),
  );

  my $err_html = sub {
    my ($msg) = @_;
    my $html = '';
    $TT->process("index.html", { baseurl => $BASEURL, error => $msg }, \$html);
    $req->respond([500, 'error', { 'Content-Type' => 'text/html' }, $html]);
  };

  AnyEvent::HTTP::http_request('POST', $state->{token_url},
    headers => { 'Content-Type' => 'application/x-www-form-urlencoded' },
    body    => $form_body,
    timeout => 15,
    sub {
      my ($body, $hdrs) = @_;
      unless (($hdrs->{Status} // 0) =~ /^2/) {
        return $err_html->("Token exchange failed ($hdrs->{Status}). Please try again.");
      }
      my $tokens = eval { decode_json($body) };
      if (!$tokens || $tokens->{error}) {
        return $err_html->("OAuth token error: " . ($tokens->{error} // 'invalid response'));
      }

      my $access_token  = $tokens->{access_token}  or return $err_html->("No access_token in response");
      my $refresh_token = $tokens->{refresh_token} // '';

      # Get user email from userinfo endpoint (if available)
      my $userinfo_url = $state->{userinfo_url};
      my $get_email_cb = sub {
        my ($email) = @_;
        $email ||= $state->{email};
        unless ($email) {
          return $err_html->("Could not determine account email from OAuth response.");
        }

        my $auth_aid     = $state->{auth_aid};
        my $account_type = $state->{account_type};
        my $imap         = $state->{imap} // {};
        my $accountid    = new_uuid_string();

        # Fastmail JMAP passthrough via OAuth: use signup_jmap with Bearer token refresh.
        if ($account_type eq 'fastmail_jmap') {
          send_backend_request($accountid, 'signup_jmap', {
            username   => $email,
            password   => $refresh_token,   # stored as encrypted refresh token
            authType   => 'fastmail_oauth',
            sessionUrl => 'https://api.fastmail.com/jmap/session',
            ($auth_aid ? (poolid => $auth_aid) : ()),
          }, sub {
            my $result = shift;
            my ($final_aid, $final_email) = @$result;
            delete $backend{$accountid} unless $final_aid eq $accountid;
            if ($auth_aid) {
              $req->respond([302, 'Found', { Location => "$BASEURL/accounts" }, '']);
              return;
            }
            my $token = _generate_token();
            send_backend_request('__accounts__', 'create_token',
              { token => $token, accountid => $final_aid,
                last_ip => _client_ip($req), last_used => time() }, sub {
              $auth_cache{"bearer:$token"} = [$final_aid, time() + $AUTH_CACHE_TTL];
              my $cookie = bake_cookie("jmap_proxy", { value => $token, path => '/', expires => '+3M' });
              $req->respond([302, 'Found',
                { 'Set-Cookie' => $cookie, Location => "$BASEURL/accounts" }, '']);
            }, sub { $err_html->('Failed to create session after OAuth login') });
          }, sub {
            my $err = shift;
            delete $backend{$accountid};
            $err_html->("Account setup failed: $err");
          });
          return;
        }

        send_backend_request($accountid, 'signup_oauth', {
          email         => $email,
          refresh_token => $refresh_token,
          account_type  => $account_type,
          %$imap,
          ($auth_aid ? (poolid => $auth_aid) : ()),
        }, sub {
          my $result = shift;
          my ($final_aid, $final_email) = @$result;
          delete $backend{$accountid} unless $final_aid eq $accountid;

          send_backend_request($final_aid, 'sync', {});
          prod_backfill($final_aid);

          if ($auth_aid) {
            $req->respond([302, 'Found', { Location => "$BASEURL/accounts" }, '']);
            return;
          }
          my $token = _generate_token();
          send_backend_request('__accounts__', 'create_token',
            { token => $token, accountid => $final_aid,
              last_ip => _client_ip($req), last_used => time() }, sub {
            $auth_cache{"bearer:$token"} = [$final_aid, time() + $AUTH_CACHE_TTL];
            my $cookie = bake_cookie("jmap_proxy", { value => $token, path => '/', expires => '+3M' });
            $req->respond([302, 'Found',
              { 'Set-Cookie' => $cookie, Location => "$BASEURL/accounts" }, '']);
          }, sub { $err_html->('Failed to create session after OAuth login') });
        }, sub {
          my $err = shift;
          delete $backend{$accountid};
          $err_html->("Account setup failed: $err");
        });
      };

      if ($userinfo_url) {
        AnyEvent::HTTP::http_get($userinfo_url,
          headers => { Authorization => "Bearer $access_token" },
          timeout => 10,
          sub {
            my ($ubody, $uhdrs) = @_;
            my $info = eval { decode_json($ubody) };
            $get_email_cb->($info->{email});
          });
      } else {
        $get_email_cb->($state->{email});
      }
    });
}

sub do_signup {
  my ($httpd, $req) = @_;

  return invalid_request($req) unless lc $req->method eq 'post';

  my %opts;
  for my $key (qw(username password imapHost imapPort imapSSL smtpHost smtpPort smtpSSL caldavURL carddavURL force)) {
    $opts{$key} = $req->parm($key);
  }

  return invalid_request($req) unless $opts{username} && $opts{password};

  $httpd->stop_request();

  _try_authenticate($req, $httpd, sub {
    my ($auth_aid) = @_;

    # Fast path: account already exists with these credentials — log in or join pool
    send_backend_request('__accounts__', 'verify_credentials',
      { username => $opts{username}, password => $opts{password} }, sub {
      my $existing = shift;
      if ($existing) {
        my $existing_aid = $existing->{accountid};
        if ($auth_aid) {
          # Already logged in — join existing account into our pool (or no-op if same)
          if ($existing_aid eq $auth_aid) {
            $req->respond([301, 'redirected', { Location => "$BASEURL/accounts" }, "Redirected"]);
          } else {
            send_backend_request('__accounts__', 'set_poolid',
              { accountid => $existing_aid, poolid => $auth_aid }, sub {
              $req->respond([301, 'redirected', { Location => "$BASEURL/accounts" }, "Redirected"]);
            }, sub {
              $req->respond([301, 'redirected', { Location => "$BASEURL/accounts" }, "Redirected"]);
            });
          }
        } else {
          # Not logged in — create a new token and log in
          my $token = _generate_token();
          send_backend_request('__accounts__', 'create_token',
            { token => $token, accountid => $existing_aid,
              last_ip => _client_ip($req), last_used => time() }, sub {
            $auth_cache{"bearer:$token"} = [$existing_aid, time() + $AUTH_CACHE_TTL];
            my $cookie = bake_cookie("jmap_proxy", { value => $token, path => '/', expires => '+3M' });
            $req->respond([301, 'redirected',
              { 'Set-Cookie' => $cookie, Location => "$BASEURL/accounts" }, "Redirected"]);
          }, sub {
            $req->respond([500, 'error', {}, 'failed to create session']);
          });
        }
        return;
      }

      # Account not found (or wrong password) — do full signup flow
      _do_signup_new($httpd, $req, $auth_aid, \%opts);
    }, sub {
      _do_signup_new($httpd, $req, $auth_aid, \%opts);
    });
  });
}

sub _do_signup_new {
  my ($httpd, $req, $auth_aid, $opts) = @_;

  $opts->{poolid} = $auth_aid if $auth_aid;
  my $accountid = new_uuid_string();

  # Step 1: send signup to a per-account child for DNS resolution + IMAP test
  send_backend_request($accountid, 'signup', $opts, sub {
    my $result = shift;

    if ($result->[0] eq 'continue') {
      # Need user confirmation — show signup.html with resolved details
      my $html = '';
      $TT->process("signup.html", $result->[1], \$html)
        || return $req->respond([500, 'error', {}, $Template::ERROR]);
      delete $backend{$accountid};
      $req->respond({ content => ['text/html', $html] });
      return;
    }

    if ($result->[0] eq 'done') {
      my ($final_accountid, $username) = @{$result}[1, 2];
      send_backend_request($final_accountid, 'sync', {});
      prod_backfill($final_accountid);
      delete $backend{$accountid} unless $final_accountid eq $accountid;

      if ($auth_aid) {
        # Already logged in — just redirect, keep existing session
        $req->respond([301, 'redirected', { Location => "$BASEURL/accounts" }, "Redirected"]);
        return;
      }

      # Not logged in — create new token
      my $token = _generate_token();
      send_backend_request('__accounts__', 'create_token',
        { token => $token, accountid => $final_accountid,
          last_ip => _client_ip($req), last_used => time() }, sub {
        $auth_cache{"bearer:$token"} = [$final_accountid, time() + $AUTH_CACHE_TTL];
        my $cookie = bake_cookie("jmap_proxy", { value => $token, path => '/', expires => '+3M' });
        $req->respond([301, 'redirected',
          { 'Set-Cookie' => $cookie, Location => "$BASEURL/accounts" }, "Redirected"]);
      }, sub {
        $req->respond([500, 'error', {}, 'failed to create session']);
      });
      return;
    }
  }, sub {
    my $err = shift;
    delete $backend{$accountid};
    if ($auth_aid) {
      $req->respond([301, 'redirected', { Location => "$BASEURL/accounts" }, "Redirected"]);
    } else {
      my $html = '';
      $TT->process("index.html", { baseurl => $BASEURL, error => "$err" }, \$html)
        || return $req->respond([500, 'error', {}, $Template::ERROR]);
      $req->respond({ content => ['text/html', $html] });
    }
  });
}

sub do_signup_jmap {
  my ($httpd, $req) = @_;
  $httpd->stop_request();

  _try_authenticate($req, $httpd, sub {
    my $auth_aid = shift;  # undef if not logged in

    my %opts = (
      sessionUrl => scalar($req->parm('sessionUrl')),
      username   => scalar($req->parm('username')),
      password   => scalar($req->parm('password')),
      authType   => scalar($req->parm('authType')) || 'basic',
    );
    $opts{poolid} = $auth_aid if $auth_aid;

    return $req->respond([400, 'bad request', {}, 'sessionUrl and password required'])
      unless $opts{sessionUrl} && $opts{password};

    my $accountid = new_uuid_string();

    send_backend_request($accountid, 'signup_jmap', \%opts, sub {
      my $result = shift;
      my ($final_aid, $email) = @$result;
      delete $backend{$accountid} unless $final_aid eq $accountid;

      if ($auth_aid) {
        $req->respond([301, 'redirected', { Location => "$BASEURL/accounts" }, "Redirected"]);
        return;
      }

      # Not logged in — create a session token
      my $token = _generate_token();
      send_backend_request('__accounts__', 'create_token',
        { token => $token, accountid => $final_aid,
          last_ip => _client_ip($req), last_used => time() }, sub {
        $auth_cache{"bearer:$token"} = [$final_aid, time() + $AUTH_CACHE_TTL];
        my $cookie = bake_cookie("jmap_proxy", { value => $token, path => '/', expires => '+3M' });
        $req->respond([301, 'redirected',
          { 'Set-Cookie' => $cookie, Location => "$BASEURL/accounts" }, "Redirected"]);
      }, sub {
        $req->respond([500, 'error', {}, 'failed to create session']);
      });
    }, sub {
      my $err = shift;
      delete $backend{$accountid};
      # Show error on the accounts page if logged in, otherwise on index
      if ($auth_aid) {
        my $html = '';
        $TT->process("accounts.html", {
          baseurl    => $BASEURL,
          auth_aid   => $auth_aid,
          accounts   => [],
          token      => undef,
          tokens     => [],
          human_time => \&_time_ago,
          jmap_error => "$err",
        }, \$html) || return $req->respond([500, 'error', {}, $Template::ERROR]);
        $req->respond([400, 'error', { 'Content-Type' => 'text/html; charset=utf-8' }, $html]);
      } else {
        my $html = '';
        $TT->process("index.html", { baseurl => $BASEURL, error => "$err" }, \$html)
          || return $req->respond([500, 'error', {}, $Template::ERROR]);
        $req->respond([400, 'error', { 'Content-Type' => 'text/html' }, $html]);
      }
    });
  });
}

sub do_accounts {
  my ($httpd, $req) = @_;

  my $method = lc $req->method;
  my $path = $req->url->path;

  $httpd->stop_request();
  _authenticate($req, $httpd, sub {
    my ($auth_aid) = @_;
    _do_accounts_authed($httpd, $req, $auth_aid, $method, $path);
  }, sub {
    $req->respond([301, 'redirected', { Location => "$BASEURL/" }, "Redirected"]);
  });
}

sub _do_accounts_authed {
  my ($httpd, $req, $auth_aid, $method, $path) = @_;

  # GET /accounts/edit?accountid=X — show edit-settings form
  if ($path eq '/accounts/edit' && $method eq 'get') {
    my $aid = $req->parm('accountid') || $auth_aid;
    $httpd->stop_request();
    send_backend_request($aid, 'get_settings', {}, sub {
      my $settings = shift;
      my $html = '';
      $TT->process("edit-settings.html", {
        baseurl    => $BASEURL,
        accountid  => $aid,
        settings   => $settings,
      }, \$html) || return $req->respond([500, 'error', {}, $Template::ERROR]);
      $req->respond([200, 'ok', { 'Content-Type' => 'text/html; charset=utf-8' }, $html]);
    }, sub {
      my $err = shift;
      $req->respond([500, 'error', {}, "get settings failed: $err"]);
    });
    return;
  }

  # POST /accounts/update — save edited settings
  if ($path eq '/accounts/update' && $method eq 'post') {
    my $aid = $req->parm('accountid') || $auth_aid;
    return invalid_request($req) unless $aid;
    $httpd->stop_request();

    my %args = (
      username   => $req->parm('username'),
      password   => $req->parm('password'),
      imapHost   => $req->parm('imapHost'),
      imapPort   => $req->parm('imapPort') || 993,
      imapSSL    => $req->parm('imapSSL')  // 2,
      smtpHost   => $req->parm('smtpHost'),
      smtpPort   => $req->parm('smtpPort') || 587,
      smtpSSL    => $req->parm('smtpSSL')  // 3,
      caldavURL  => $req->parm('caldavURL')  || '',
      carddavURL => $req->parm('carddavURL') || '',
    );

    send_backend_request($aid, 'update_settings', \%args, sub {
      # Kill the running worker so next request gets fresh IMAP connection
      if ($backend{$aid}) {
        send_backend_request($aid, 'delete', {}, sub { delete $backend{$aid} }, sub { delete $backend{$aid} });
      }
      $req->respond([301, 'redirected', { Location => "$BASEURL/accounts" }, "Redirected"]);
    }, sub {
      my $err = shift;
      # Show error back on the edit form
      my $html = '';
      $TT->process("edit-settings.html", {
        baseurl   => $BASEURL,
        accountid => $aid,
        settings  => \%args,
        error     => $err,
      }, \$html) || return $req->respond([500, 'error', {}, $Template::ERROR]);
      $req->respond([200, 'ok', { 'Content-Type' => 'text/html; charset=utf-8' }, $html]);
    });
    return;
  }

  # POST /accounts/tokens/delete — revoke a token
  if ($path eq '/accounts/tokens/delete' && $method eq 'post') {
    my $token = $req->parm('token');
    return invalid_request($req) unless $token;
    $httpd->stop_request();

    my $cookies = crush_cookie($req->headers->{cookie} || '');
    my $my_token = $cookies->{jmap_proxy};
    # Invalidate auth cache entry for this token
    delete $auth_cache{"bearer:$token"};
    delete $token_touch{$token};

    my $is_fetch = ($req->headers->{accept} || '') =~ m{application/json};
    send_backend_request('__accounts__', 'delete_token', { token => $token }, sub {
      # If the user deleted their own session token, log them out
      if ($my_token && $token eq $my_token) {
        my $cookie = bake_cookie("jmap_proxy", { value => '', path => '/', expires => '-1d' });
        if ($is_fetch) {
          $req->respond([200, 'ok', { 'Set-Cookie' => $cookie,
            'Content-Type' => 'application/json' }, '{"ok":1,"logout":true}']);
        } else {
          $req->respond([301, 'redirected',
            { 'Set-Cookie' => $cookie, Location => "$BASEURL/" }, "Redirected"]);
        }
      } else {
        if ($is_fetch) {
          $req->respond([200, 'ok', { 'Content-Type' => 'application/json' }, '{"ok":1}']);
        } else {
          $req->respond([301, 'redirected', { Location => "$BASEURL/accounts" }, "Redirected"]);
        }
      }
    }, sub {
      my $err = shift;
      $req->respond([500, 'error', {}, "delete token failed: $err"]);
    });
    return;
  }

  # POST /accounts/detach — detach an account from the pool
  if ($path eq '/accounts/detach' && $method eq 'post') {
    my $aid = $req->parm('accountid');
    return invalid_request($req) unless $aid;
    $httpd->stop_request();
    # Set the account's poolid to itself
    send_backend_request('__accounts__', 'set_poolid', { accountid => $aid, poolid => $aid }, sub {
      $req->respond([301, 'redirected', { Location => "$BASEURL/accounts" }, "Redirected"]);
    }, sub {
      my $err = shift;
      $req->respond([500, 'error', {}, "detach failed: $err"]);
    });
    return;
  }

  # POST /accounts/delete — delete an account
  if ($path eq '/accounts/delete' && $method eq 'post') {
    my $aid = $req->parm('accountid');
    return invalid_request($req) unless $aid;
    $httpd->stop_request();

    my $finish_delete = sub {
      send_backend_request('__accounts__', 'delete_account', { accountid => $aid }, sub {
        # If we deleted the authenticated account, clear cookie and go home
        if ($aid eq $auth_aid) {
          my $cookie = bake_cookie("jmap_proxy", { value => '', path => '/', expires => '-1d' });
          $req->respond([301, 'redirected',
            { 'Set-Cookie' => $cookie, Location => "$BASEURL/" }, "Redirected"]);
        } else {
          $req->respond([301, 'redirected', { Location => "$BASEURL/accounts" }, "Redirected"]);
        }
      }, sub {
        my $err = shift;
        $req->respond([500, 'error', {}, "delete failed: $err"]);
      });
    };

    # Tell per-account child to clean up if running
    if ($backend{$aid}) {
      send_backend_request($aid, 'delete', {}, sub {
        delete $backend{$aid};
        $finish_delete->();
      }, sub {
        delete $backend{$aid};
        $finish_delete->();
      });
    } else {
      $finish_delete->();
    }
    return;
  }

  # GET /accounts — show the accounts page
  $httpd->stop_request();
  my $cookies = crush_cookie($req->headers->{cookie} || '');
  my $my_token = $cookies->{jmap_proxy};
  send_backend_request('__accounts__', 'get_pool', { accountid => $auth_aid }, sub {
    my $pool = shift;
    send_backend_request('__accounts__', 'list_tokens', { poolid => $pool->{poolid} }, sub {
      my $tokens = shift;
      my $html = '';
      $TT->process("accounts.html", {
        baseurl     => $BASEURL,
        auth_aid    => $auth_aid,
        accounts    => $pool->{accounts} || [],
        token       => $my_token,
        tokens      => $tokens || [],
        human_time  => \&_time_ago,
      }, \$html) || return $req->respond([500, 'error', {}, $Template::ERROR]);
      $req->respond([200, 'ok', { 'Content-Type' => 'text/html; charset=utf-8' }, $html]);
    }, sub {
      # Token listing failed — still show the page without tokens
      my $html = '';
      $TT->process("accounts.html", {
        baseurl    => $BASEURL,
        auth_aid   => $auth_aid,
        accounts   => $pool->{accounts} || [],
        token      => $my_token,
        tokens     => [],
        human_time => \&_time_ago,
      }, \$html) || return $req->respond([500, 'error', {}, $Template::ERROR]);
      $req->respond([200, 'ok', { 'Content-Type' => 'text/html; charset=utf-8' }, $html]);
    });
  }, sub {
    my $err = shift;
    $req->respond([500, 'error', {}, "error: $err"]);
  });
}

sub do_logout {
  my ($httpd, $req) = @_;
  my $cookie = bake_cookie("jmap_proxy", { value => '', path => '/', expires => '-1d' });
  $req->respond([301, 'redirected',
    { 'Set-Cookie' => $cookie, Location => "$BASEURL/" }, "Redirected"]);
}

# GET /eventsource — Server-Sent Events endpoint (RFC 8620 §7.3)
# AnyEvent::HTTPD supports streaming by passing a CODE ref as the response body.
# The CODE is called with a $chunk_cb whenever the write buffer drains. Saving
# $chunk_cb and calling it later (from PushEvent or the ping timer) writes data
# and re-arms the drain callback for the next event.
sub do_eventsource {
  my ($httpd, $req) = @_;
  $httpd->stop_request();

  _authenticate($req, $httpd, sub {
    my $auth_aid = shift;

    my $ping_interval = int($req->parm('ping') || 300);
    $ping_interval = 30 unless $ping_interval > 0;  # minimum for cleanup detection
    my $close_after = $req->parm('closeafter') || '';

    send_backend_request('__accounts__', 'get_pool', { accountid => $auth_aid }, sub {
      my $pool = shift;
      my @aids = map { $_->{accountid} } @{$pool->{accounts} || []};

      my $conn_id = ++$push_conn_counter;
      my $chunk_cb_slot;  # current drain callback; undef briefly while the hdl is flushing
      my $dead = 0;       # set to 1 once the connection is confirmed dead

      my $ping_timer;

      my $cleanup = sub {
        return if $dead;
        $dead = 1;
        delete $PushMap{$_}{$conn_id} for @aids;
        undef $ping_timer;
        warn "SSE $conn_id closed ($auth_aid)\n";
      };

      # Write one SSE event. Returns 1=ok, 0=dead. If chunk_cb_slot is
      # temporarily undef (mid-flush), the event is silently dropped — the
      # next sync will catch up.  Death is detected when chunk_cb returns 0.
      my $write_sse = sub {
        my ($event, $data_ref) = @_;
        return 0 if $dead;
        return 1 unless defined $chunk_cb_slot;  # mid-flush: drop but not dead
        my $cb = $chunk_cb_slot;
        $chunk_cb_slot = undef;
        my $line = "event: $event\r\ndata: " . JSON::XS::encode_json($data_ref) . "\r\n\r\n";
        my $ok = $cb->($line);
        unless ($ok) { $cleanup->(); return 0; }
        # RFC 8620 §7.3 closeafter — close after first matching event type
        if ($close_after && $close_after eq $event) {
          $cleanup->();
          $cb->(undef);  # empty write → response_done
          return 0;
        }
        return 1;
      };

      # Register for all pool accounts
      my $conn = { write => $write_sse, accountids => \@aids };
      $PushMap{$_}{$conn_id} = $conn for @aids;

      # Ping keepalive — also acts as dead-connection detector
      $ping_timer = AnyEvent->timer(
        after    => $ping_interval,
        interval => $ping_interval,
        cb       => sub { $write_sse->('ping', { interval => $ping_interval + 0 }) },
      );

      warn "SSE $conn_id opened ($auth_aid, pool: @aids, ping: ${ping_interval}s)\n";

      # AnyEvent::HTTPD streaming: CODE ref is called with a $chunk_cb each time
      # the write buffer drains. We save it and call it when we have data to send.
      $req->respond([200, 'ok', {
        'Content-Type'      => 'text/event-stream; charset=utf-8',
        'Cache-Control'     => 'no-cache',
        'X-Accel-Buffering' => 'no',   # disable nginx/Caddy buffering
      }, sub {
        my ($cb) = @_;
        $chunk_cb_slot = $cb;
        # Don't call $cb here — wait for a push event or ping timer
      }]);

    }, sub {
      $req->respond([500, 'error', {}, 'Failed to get pool info']);
    });

  }, sub {
    $req->respond([401, 'unauthorized', { 'WWW-Authenticate' => 'Bearer realm="JMAP"' }, 'Unauthorized']);
  });
}

# ---------------------------------------------------------------------------
# Minimal OIDC provider (used by tmail-web / Twake Mail)
# ---------------------------------------------------------------------------

# GET /oauth/jwks — public key for id_token signature verification
sub do_oidc_jwks {
  my ($httpd, $req) = @_;
  my $key  = _oidc_rsa_key();
  my $pub  = $key->export_key_jwk('public', 1);  # hashref
  $pub->{use} = 'sig';
  $pub->{alg} = 'RS256';
  $pub->{kid} = 'jmap-proxy-1';
  my $body = encode_json({ keys => [$pub] });
  $req->respond({ content => ['application/json', $body] });
}

# GET /oauth/authorize — show login form or issue auth code
sub do_oidc_authorize {
  my ($httpd, $req) = @_;
  my $redirect_uri  = $req->parm('redirect_uri')  // '';
  my $state         = $req->parm('state')         // '';
  my $client_id     = $req->parm('client_id')     // '';

  unless ($redirect_uri) {
    return $req->respond([400, 'bad request', {}, 'Missing redirect_uri']);
  }

  # If already authenticated, issue code immediately
  $httpd->stop_request();
  _try_authenticate($req, $httpd, sub {
    my ($auth_aid) = @_;
    if ($auth_aid) {
      _oidc_issue_code($auth_aid, $redirect_uri, $state, $req);
      return;
    }
    # Not logged in — show login form with OIDC params embedded
    my $html = '';
    my $error = $req->parm('login_error') // '';
    $TT->process('index.html', {
      baseurl  => $BASEURL,
      step     => 'oidc_login',
      oidc     => {
        redirect_uri => $redirect_uri,
        state        => $state,
        client_id    => $client_id,
      },
      ($error ? (error => $error) : ()),
    }, \$html) || return $req->respond([500, 'error', {}, $Template::ERROR]);
    $req->respond({ content => ['text/html', $html] });
  });
}

# POST /oauth/authorize — validate credentials, issue code or show error
sub do_oidc_authorize_post {
  my ($httpd, $req) = @_;
  my $redirect_uri = $req->parm('redirect_uri') // '';
  my $state        = $req->parm('state')        // '';
  my $username     = $req->parm('username')     // '';
  my $password     = $req->parm('password')     // '';

  unless ($redirect_uri && $username && $password) {
    return $req->respond([400, 'bad request', {}, 'Missing required fields']);
  }

  $httpd->stop_request();
  send_backend_request('__accounts__', 'auth',
    { username => $username, password => $password,
      last_ip => _client_ip($req), last_used => time() },
    sub {
      my $result = shift;
      unless ($result && $result->{accountid}) {
        # Bad credentials — re-show the form with error
        my $html = '';
        $TT->process('index.html', {
          baseurl => $BASEURL,
          step    => 'oidc_login',
          error   => 'Invalid email or password.',
          oidc    => { redirect_uri => $redirect_uri, state => $state },
        }, \$html) || return $req->respond([500, 'error', {}, $Template::ERROR]);
        return $req->respond([401, 'unauthorized',
          { 'Content-Type' => 'text/html' }, $html]);
      }
      my $aid = $result->{accountid};
      $auth_cache{"bearer:$result->{token}"} = [$aid, time() + $AUTH_CACHE_TTL]
        if $result->{token};
      _oidc_issue_code($aid, $redirect_uri, $state, $req);
    },
    sub { $req->respond([500, 'error', {}, 'Authentication backend error']) }
  );
}

sub _oidc_issue_code {
  my ($aid, $redirect_uri, $state, $req) = @_;
  # Look up email for this account
  send_backend_request('__accounts__', 'get_pool',
    { accountid => $aid },
    sub {
      my $pool = shift // {};
      my ($acct) = grep { $_->{accountid} eq $aid } @{$pool->{accounts} || []};
      my $email = $acct ? ($acct->{email} // $acct->{username} // '') : '';

      my $code = _generate_token();
      $oidc_codes{$code} = {
        accountid    => $aid,
        email        => $email,
        redirect_uri => $redirect_uri,
        exp          => time() + 300,
      };
      my $loc = URI->new($redirect_uri);
      $loc->query_param(code  => $code);
      $loc->query_param(state => $state) if $state;
      $req->respond([302, 'Found', { Location => "$loc" }, '']);
    },
    sub { $req->respond([500, 'error', {}, 'Failed to look up account']) }
  );
}

# POST /oauth/token — exchange code for access_token + id_token
sub do_oidc_token {
  my ($httpd, $req) = @_;
  return $req->respond([405, 'method not allowed', {}, ''])
    unless lc $req->method eq 'post';

  my $grant_type   = $req->parm('grant_type')   // '';
  my $code         = $req->parm('code')         // '';
  my $redirect_uri = $req->parm('redirect_uri') // '';

  unless ($grant_type eq 'authorization_code' && $code) {
    return $req->respond([400, 'bad request', {},
      encode_json({ error => 'invalid_request' })]);
  }

  my $entry = delete $oidc_codes{$code};
  unless ($entry && $entry->{exp} > time()) {
    return $req->respond([400, 'bad request', {},
      encode_json({ error => 'invalid_grant' })]);
  }
  if ($redirect_uri && $entry->{redirect_uri} ne $redirect_uri) {
    return $req->respond([400, 'bad request', {},
      encode_json({ error => 'invalid_grant' })]);
  }

  $httpd->stop_request();
  # Create a real Bearer token for this account
  my $token = _generate_token();
  send_backend_request('__accounts__', 'create_token',
    { token => $token, accountid => $entry->{accountid},
      last_ip => _client_ip($req), last_used => time() },
    sub {
      $auth_cache{"bearer:$token"} = [$entry->{accountid}, time() + $AUTH_CACHE_TTL];

      my $id_token = JMAP::OAuth::OIDC->id_token(
        aid     => $entry->{accountid},
        email   => $entry->{email},
        baseurl => $BASEURL,
        key     => _oidc_rsa_key(),
      );

      my $body = encode_json({
        access_token  => $token,
        token_type    => 'Bearer',
        expires_in    => 3600 * 24 * 90,
        id_token      => $id_token,
      });
      $req->respond({ content => ['application/json', $body] });
    },
    sub { $req->respond([500, 'error', {}, encode_json({ error => 'server_error' })]) }
  );
}

# GET /oauth/userinfo — return user's email from Bearer token
sub do_oidc_userinfo {
  my ($httpd, $req) = @_;
  $httpd->stop_request();
  _authenticate($req, $httpd, sub {
    my ($aid) = @_;
    send_backend_request('__accounts__', 'get_pool', { accountid => $aid }, sub {
      my $pool = shift // {};
      my ($acct) = grep { $_->{accountid} eq $aid } @{$pool->{accounts} || []};
      my $email = $acct ? ($acct->{email} // $acct->{username} // '') : '';
      $req->respond({ content => ['application/json', encode_json({
        sub   => $aid,
        email => $email,
        email_verified => JSON::true,
      })]});
    }, sub { $req->respond([500, 'error', {}, '{}']) });
  }, sub {
    $req->respond([401, 'unauthorized',
      { 'WWW-Authenticate' => 'Bearer' }, encode_json({ error => 'unauthorized' })]);
  });
}

#
# Start HTTP server
#

my $port = $ENV{JMAP_PORT} || 9000;
my $httpd = AnyEvent::HTTPD->new(port => $port);

$httpd->reg_cb(request => sub { $stat{http_requests}++ });

$httpd->reg_cb(
  '/.well-known'      => \&do_wellknown,
  '/session'          => \&do_session,
  '/eventsource'      => \&do_eventsource,
  '/jmap'             => \&do_jmap,
  '/upload'           => \&do_upload,
  '/raw'              => \&do_raw,
  '/discover'         => \&do_discover,
  '/cb/oauth'         => \&do_cb_oauth,
  '/signup'           => \&do_signup,
  '/signup_jmap'      => \&do_signup_jmap,
  '/accounts'         => \&do_accounts,
  '/logout'           => \&do_logout,
  '/main.css'         => \&do_static,
  '/assets'           => \&do_static,
  '/oauth/authorize'  => sub {
    my ($httpd, $req) = @_;
    lc($req->method) eq 'post'
      ? do_oidc_authorize_post($httpd, $req)
      : do_oidc_authorize($httpd, $req);
  },
  '/oauth/token'      => \&do_oidc_token,
  '/oauth/userinfo'   => \&do_oidc_userinfo,
  '/oauth/jwks'       => \&do_oidc_jwks,
  '/'                 => \&do_landing,
);

warn "JMAP proxy listening on port $port\n";
warn "  Data: $datadir\n";
warn "  Base URL: $BASEURL\n";

#
# Management API & UI
#

sub mgmt_api_accounts {
  my ($httpd, $req) = @_;
  my $method = lc $req->method;
  my $path = $req->url->path;

  if ($path eq '/api/accounts' && $method eq 'get') {
    $httpd->stop_request();
    send_backend_request('__accounts__', 'list_accounts', {}, sub {
      my $rows = shift;
      $req->respond([200, 'ok',
        { 'Content-Type' => 'application/json' },
        JSON::XS::encode_json($rows)]);
    }, sub {
      my $err = shift;
      $req->respond([500, 'error',
        { 'Content-Type' => 'application/json' },
        JSON::XS::encode_json({ error => "$err" })]);
    });
    return;
  }

  if ($path =~ m{^/api/accounts/([^/]+)$} && $method eq 'get') {
    my $aid = $1;
    $httpd->stop_request();
    send_backend_request('__accounts__', 'get_account', { accountid => $aid }, sub {
      my $row = shift;
      unless ($row) {
        $req->respond([404, 'not found', {}, '{"error":"not found"}']);
        return;
      }
      $req->respond([200, 'ok',
        { 'Content-Type' => 'application/json' },
        JSON::XS::encode_json($row)]);
    }, sub {
      my $err = shift;
      $req->respond([500, 'error',
        { 'Content-Type' => 'application/json' },
        JSON::XS::encode_json({ error => "$err" })]);
    });
    return;
  }

  if ($path eq '/api/accounts' && $method eq 'post') {
    my $data = eval { decode_json($req->content) };
    return $req->respond([400, 'bad request', {}, '{"error":"invalid JSON"}']) unless $data;
    return $req->respond([400, 'bad request', {}, '{"error":"accountid required"}'])
      unless $data->{accountid};

    my $aid = $data->{accountid};
    $httpd->stop_request();

    if ($data->{sessionUrl}) {
      # JMAP passthrough account — signup_jmap creates the accounts.sqlite3 entry itself.
      # The worker is keyed by $aid so signup_jmap uses it as the new accountid.
      delete $backend{$aid} if $backend{$aid};
      send_backend_request($aid, 'signup_jmap', $data, sub {
        my ($final_aid, $email) = @{shift()};
        delete $backend{$aid} if $aid ne $final_aid;
        $req->respond([201, 'created',
          { 'Content-Type' => 'application/json' },
          JSON::XS::encode_json({ accountid => $final_aid, type => 'jmap', email => $email })]);
      }, sub {
        my $err = shift;
        delete $backend{$aid};
        $req->respond([500, 'error',
          { 'Content-Type' => 'application/json' },
          JSON::XS::encode_json({ error => "$err" })]);
      });
      return;
    }

    # IMAP account — Step 1: Create account in accounts DB via __accounts__ child
    send_backend_request('__accounts__', 'create_account', $data, sub {
      my $result = shift;

      # Kill existing backend child so it reconnects with new config
      delete $backend{$aid} if $backend{$aid};

      # Step 2: If IMAP config provided, set up via per-account child
      if ($data->{imapHost}) {
        send_backend_request($aid, 'setup', $data, sub {
          $req->respond([201, 'created',
            { 'Content-Type' => 'application/json' },
            JSON::XS::encode_json({ accountid => $aid, type => $result->{type} })]);
        }, sub {
          my $err = shift;
          # Account created but sync failed
          $req->respond([201, 'created',
            { 'Content-Type' => 'application/json' },
            JSON::XS::encode_json({ accountid => $aid, type => $result->{type},
              warning => "setup failed: $err" })]);
        });
      }
      else {
        $req->respond([201, 'created',
          { 'Content-Type' => 'application/json' },
          JSON::XS::encode_json({ accountid => $aid, type => $result->{type} })]);
      }
    }, sub {
      my $err = shift;
      $req->respond([500, 'error',
        { 'Content-Type' => 'application/json' },
        JSON::XS::encode_json({ error => "$err" })]);
    });
    return;
  }

  if ($path =~ m{^/api/accounts/([^/]+)$} && $method eq 'delete') {
    my $aid = $1;
    $httpd->stop_request();

    # Tell the per-account child to clean up first (if running)
    if ($backend{$aid}) {
      send_backend_request($aid, 'delete', {}, sub {
        delete $backend{$aid};
        # Now remove from accounts DB
        send_backend_request('__accounts__', 'delete_account', { accountid => $aid }, sub {
          my $result = shift;
          $req->respond([200, 'ok',
            { 'Content-Type' => 'application/json' },
            JSON::XS::encode_json($result)]);
        }, sub {
          my $err = shift;
          $req->respond([500, 'error',
            { 'Content-Type' => 'application/json' },
            JSON::XS::encode_json({ error => "$err" })]);
        });
      }, sub {
        # Per-account child error, still delete from accounts DB
        delete $backend{$aid};
        send_backend_request('__accounts__', 'delete_account', { accountid => $aid }, sub {
          my $result = shift;
          $req->respond([200, 'ok',
            { 'Content-Type' => 'application/json' },
            JSON::XS::encode_json($result)]);
        }, sub {
          my $err = shift;
          $req->respond([500, 'error',
            { 'Content-Type' => 'application/json' },
            JSON::XS::encode_json({ error => "$err" })]);
        });
      });
    }
    else {
      send_backend_request('__accounts__', 'delete_account', { accountid => $aid }, sub {
        my $result = shift;
        $req->respond([200, 'ok',
          { 'Content-Type' => 'application/json' },
          JSON::XS::encode_json($result)]);
      }, sub {
        my $err = shift;
        $req->respond([500, 'error',
          { 'Content-Type' => 'application/json' },
          JSON::XS::encode_json({ error => "$err" })]);
      });
    }
    return;
  }

  if ($path =~ m{^/api/accounts/([^/]+)/sync$} && $method eq 'post') {
    my $aid = $1;
    $httpd->stop_request();
    send_backend_request($aid, 'sync', {}, sub {
      $req->respond([200, 'ok',
        { 'Content-Type' => 'application/json' },
        JSON::XS::encode_json({ synced => $aid })]);
    }, sub {
      my $err = shift;
      $req->respond([500, 'error',
        { 'Content-Type' => 'application/json' },
        JSON::XS::encode_json({ error => "$err" })]);
    });
    return;
  }

  return $req->respond([404, 'not found', {}, '{"error":"unknown endpoint"}']);
}

sub mgmt_dashboard {
  my ($httpd, $req) = @_;
  my $html = <<'HTML';
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>JMAP Proxy - Management</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: system-ui, sans-serif; background: #f5f5f5; color: #333; line-height: 1.6; }
    .container { max-width: 900px; margin: 0 auto; padding: 20px; }
    h1 { margin-bottom: 20px; color: #2c3e50; }
    h2 { margin: 20px 0 10px; color: #34495e; }
    table { width: 100%; border-collapse: collapse; background: white; border-radius: 8px; overflow: hidden; box-shadow: 0 1px 3px rgba(0,0,0,0.1); margin-bottom: 20px; }
    th, td { padding: 10px 14px; text-align: left; border-bottom: 1px solid #eee; }
    th { background: #2c3e50; color: white; font-weight: 500; }
    tr:hover { background: #f8f9fa; }
    button, input[type=submit] { padding: 6px 14px; border: none; border-radius: 4px; cursor: pointer; font-size: 14px; }
    .btn-sync { background: #3498db; color: white; }
    .btn-delete { background: #e74c3c; color: white; }
    .btn-add { background: #27ae60; color: white; padding: 10px 20px; font-size: 16px; }
    .btn-sync:hover { background: #2980b9; }
    .btn-delete:hover { background: #c0392b; }
    .btn-add:hover { background: #219a52; }
    .actions { display: flex; gap: 6px; }
    .form-group { margin-bottom: 12px; }
    .form-group label { display: block; font-weight: 500; margin-bottom: 4px; }
    .form-group input { width: 100%; padding: 8px; border: 1px solid #ddd; border-radius: 4px; font-size: 14px; }
    .card { background: white; border-radius: 8px; padding: 20px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); margin-bottom: 20px; }
    .hidden { display: none; }
    .status { font-size: 12px; color: #888; }
    #message { padding: 10px; border-radius: 4px; margin-bottom: 10px; }
    .msg-ok { background: #d4edda; color: #155724; }
    .msg-err { background: #f8d7da; color: #721c24; }
  </style>
</head>
<body>
<div class="container">
  <h1>JMAP Proxy Management</h1>
  <div id="message" class="hidden"></div>

  <table>
    <thead>
      <tr><th>Account ID</th><th>Type</th><th>Host</th><th>Folders</th><th>Messages</th><th>Actions</th></tr>
    </thead>
    <tbody id="accounts"></tbody>
  </table>

  <button class="btn-add" onclick="toggleForm()">+ Add Account</button>

  <div id="add-form" class="card hidden" style="margin-top: 20px;">
    <h2>Add Account</h2>
    <div class="form-group"><label>Account ID</label><input id="f-aid" placeholder="user1"></div>
    <div class="form-group"><label>Type</label><input id="f-type" value="imap"></div>
    <div class="form-group"><label>IMAP Host</label><input id="f-host" placeholder="imap.example.com"></div>
    <div class="form-group"><label>IMAP Port</label><input id="f-port" value="993"></div>
    <div class="form-group"><label>Username</label><input id="f-user" placeholder="user@example.com"></div>
    <div class="form-group"><label>Password</label><input id="f-pass" type="password"></div>
    <div class="form-group"><label>CalDAV URL (optional)</label><input id="f-caldav" placeholder="https://example.com"></div>
    <div class="form-group"><label>CardDAV URL (optional)</label><input id="f-carddav" placeholder="https://example.com"></div>
    <div style="margin-top: 16px;">
      <button class="btn-add" onclick="addAccount()">Create Account</button>
    </div>
  </div>
</div>
<script>
function msg(text, ok) {
  var el = document.getElementById('message');
  el.textContent = text;
  el.className = ok ? 'msg-ok' : 'msg-err';
  setTimeout(function() { el.className = 'hidden'; }, 4000);
}
function loadAccounts() {
  fetch('/api/accounts').then(r => r.json()).then(data => {
    var tb = document.getElementById('accounts');
    tb.innerHTML = '';
    data.forEach(function(a) {
      var tr = document.createElement('tr');
      tr.innerHTML = '<td>' + a.accountid + '</td>'
        + '<td>' + a.type + '</td>'
        + '<td>' + (a.imapHost || '-') + ':' + (a.imapPort || '') + '</td>'
        + '<td>' + (a.folders || 0) + '</td>'
        + '<td>' + (a.messages || 0) + '</td>'
        + '<td class="actions">'
        + '<button class="btn-sync" onclick="syncAccount(\'' + a.accountid + '\')">Sync</button>'
        + '<button class="btn-delete" onclick="deleteAccount(\'' + a.accountid + '\')">Delete</button>'
        + '</td>';
      tb.appendChild(tr);
    });
  });
}
function syncAccount(aid) {
  fetch('/api/accounts/' + aid + '/sync', { method: 'POST' })
    .then(r => r.json())
    .then(d => { msg(d.error ? 'Error: ' + d.error : 'Synced ' + aid, !d.error); loadAccounts(); });
}
function deleteAccount(aid) {
  if (!confirm('Delete account ' + aid + '?')) return;
  fetch('/api/accounts/' + aid, { method: 'DELETE' })
    .then(r => r.json())
    .then(d => { msg('Deleted ' + aid, true); loadAccounts(); });
}
function toggleForm() { document.getElementById('add-form').classList.toggle('hidden'); }
function addAccount() {
  var body = {
    accountid: document.getElementById('f-aid').value,
    type: document.getElementById('f-type').value,
    imapHost: document.getElementById('f-host').value,
    imapPort: parseInt(document.getElementById('f-port').value) || 993,
    username: document.getElementById('f-user').value,
    password: document.getElementById('f-pass').value,
    caldavURL: document.getElementById('f-caldav').value,
    carddavURL: document.getElementById('f-carddav').value,
  };
  fetch('/api/accounts', { method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(body) })
    .then(r => r.json())
    .then(d => {
      if (d.error) { msg('Error: ' + d.error, false); }
      else { msg('Created ' + d.accountid, true); document.getElementById('add-form').classList.add('hidden'); loadAccounts(); }
    });
}
loadAccounts();
</script>
</body>
</html>
HTML
  $req->respond([200, 'ok', { 'Content-Type' => 'text/html; charset=utf-8' }, $html]);
}

my $mgmt_port = $ENV{JMAP_MGMT_PORT} || 8080;
my $mgmt_host = $ENV{JMAP_MGMT_HOST} || '127.0.0.1';
my $mgmt = AnyEvent::HTTPD->new(
  port => $mgmt_port,
  host => $mgmt_host,
  allowed_methods => [qw(GET POST DELETE PUT)],
);

sub mgmt_healthz {
  my ($httpd, $req) = @_;
  my $now = time();
  my $children = grep { $_ ne '__accounts__' } keys %backend;
  $req->respond([200, 'ok',
    { 'Content-Type' => 'application/json' },
    JSON::XS::encode_json({
      status   => 'ok',
      uptime   => $now - $start_time,
      children => $children,
      pid      => $$,
    })]);
}

sub mgmt_metrics {
  my ($httpd, $req) = @_;

  my $now    = time();
  my $uptime = $now - $start_time;

  my $workers = grep { $_ ne '__accounts__' } keys %backend;
  my $queue   = 0; $queue += scalar(keys %$_) for values %waiting;
  my $sse     = 0; for my $m (values %PushMap) { $sse += scalar keys %$m }
  my $bf      = scalar keys %backfilling;

  my $total_backend_cmds = 0;
  $total_backend_cmds += $_->[1] for values %backend;

  my @out;
  my $g = sub {  # gauge
    my ($name, $help, $val) = @_;
    push @out, "# HELP $name $help", "# TYPE $name gauge", "$name $val";
  };
  my $c = sub {  # counter
    my ($name, $help, $val) = @_;
    push @out, "# HELP $name $help", "# TYPE $name counter", "${name}_total $val";
  };

  $g->('jmap_uptime_seconds',          'Seconds since proxy process started',            $uptime);
  $g->('jmap_backend_workers_active',  'Active per-account backend worker processes',    $workers);
  $g->('jmap_backend_queue_depth',     'Total pending backend requests across all workers', $queue);
  $g->('jmap_sse_connections_active',  'Open Server-Sent Events connections',            $sse);
  $g->('jmap_backfilling_accounts',    'Accounts currently running a backfill loop',     $bf);
  $g->('jmap_auth_cache_entries',      'Entries currently in the auth token cache',      scalar(keys %auth_cache));

  $c->('jmap_http_requests',           'HTTP requests received on the JMAP port',        $stat{http_requests});
  $c->('jmap_mgmt_requests',           'HTTP requests received on the management port',  $stat{mgmt_requests});
  $c->('jmap_method_calls',            'Individual JMAP method calls dispatched',        $stat{jmap_method_calls});
  $c->('jmap_backend_requests',        'Backend worker requests sent (all workers)',      $total_backend_cmds);
  $c->('jmap_backend_errors',          'Backend worker error responses received',        $stat{backend_errors});
  $c->('jmap_auth_cache_hits',         'Auth cache lookups that returned a cached result', $stat{auth_cache_hits});
  $c->('jmap_auth_cache_misses',       'Auth cache lookups that required a backend call',  $stat{auth_cache_misses});

  if (%sync_times) {
    push @out, '# HELP jmap_account_last_sync_age_seconds Seconds since last successful sync per account';
    push @out, '# TYPE jmap_account_last_sync_age_seconds gauge';
    for my $aid (sort keys %sync_times) {
      my $label = $aid =~ s/"/\\"/gr;
      push @out, "jmap_account_last_sync_age_seconds{accountid=\"$label\"} " . ($now - $sync_times{$aid});
    }
  }

  $req->respond([200, 'ok',
    { 'Content-Type' => 'text/plain; version=0.0.4; charset=utf-8' },
    join("\n", @out) . "\n"]);
}

$mgmt->reg_cb(request => sub { $stat{mgmt_requests}++ });

$mgmt->reg_cb(
  '/healthz' => \&mgmt_healthz,
  '/metrics' => \&mgmt_metrics,
  '/api'     => \&mgmt_api_accounts,
  '/'        => \&mgmt_dashboard,
);

warn "Management UI on http://$mgmt_host:$mgmt_port/\n";

#
# Idle timeout: reap backend children that haven't been used recently
#
my $idle_timeout = $ENV{JMAP_IDLE_TIMEOUT} || 300;  # seconds, 0 to disable
my $idle_timer;
if ($idle_timeout) {
  $idle_timer = AnyEvent->timer(
    after    => 60,
    interval => 60,
    cb       => sub {
      my $now = time();
      for my $name (keys %backend) {
        next if $name eq '__accounts__';  # keep accounts worker alive
        next if %{$waiting{$name} || {}};  # has in-flight requests
        my $idle = $now - ($backend{$name}[3] || 0);
        if ($idle > $idle_timeout) {
          warn "Idle timeout: closing $name (idle ${idle}s)\n";
          delete $backend{$name};
          delete $waiting{$name};
          # Child will see EOF on socketpair and exit
        }
      }
    },
  );
}

#
# Token touch flush: write cached last_used/last_ip to accounts DB every 5 min
#
sub _flush_token_touches {
  return unless %token_touch;
  my @entries = map { [$_, @{$token_touch{$_}}] } keys %token_touch;
  %token_touch = ();
  send_backend_request('__accounts__', 'touch_tokens', { tokens => \@entries },
    sub { }, sub { });
}

my $token_flush_timer = AnyEvent->timer(
  after    => $TOKEN_TOUCH_INTERVAL,
  interval => $TOKEN_TOUCH_INTERVAL,
  cb       => \&_flush_token_touches,
);

#
# Periodic sync: send sync to each idle per-account child every 30s.
# Backfill runs in a SEPARATE "$accountid:backfill" child via prod_backfill.
# RULE: backfill and sync/jmap MUST NEVER share a worker process.
#
my $SYNC_INTERVAL = $ENV{JMAP_SYNC_INTERVAL} || 30;

# prod_backfill: repeatedly send 'backfill' to a dedicated backfill child
# until backfill() returns false (nothing left to backfill). Mirrors
# server.pl's prod_backfill() which uses "$accountid:backfill" as the
# backend name to guarantee a separate process from the sync/jmap worker.
sub prod_backfill {
  my ($accountid) = @_;
  return if $backfilling{$accountid};
  $backfilling{$accountid} = 1;

  my $do_backfill;
  $do_backfill = sub {
    send_backend_request("$accountid:backfill", 'backfill', {}, sub {
      my $more = shift;
      if ($more) {
        my $t; $t = AnyEvent->timer(after => 10, cb => sub {
          $t = undef;
          $do_backfill->();
        });
      } else {
        # Backfill complete — clear flag in DB so we don't restart on next boot
        send_backend_request('__accounts__', 'clear_backfill', { accountid => $accountid },
          sub {}, sub {});
        delete $backfilling{$accountid};
      }
    }, sub {
      delete $backfilling{$accountid};
    });
  };
  $do_backfill->();
}

my $sync_timer = AnyEvent->timer(
  after    => $SYNC_INTERVAL,
  interval => $SYNC_INTERVAL,
  cb       => sub {
    for my $name (keys %backend) {
      next if $name eq '__accounts__';
      next if $name =~ /:/;  # skip backfill and other sub-workers
      next if %{$waiting{$name} || {}};  # skip if handling a request
      send_backend_request($name, 'sync', {}, sub {}, sub {});
    }
  },
);

#
# On startup: resume backfill for any accounts that didn't finish last time
#
my $startup_backfill_timer;
$startup_backfill_timer = AnyEvent->timer(after => 5, cb => sub {
  $startup_backfill_timer = undef;
  send_backend_request('__accounts__', 'get_needs_backfill', {}, sub {
    my $aids = shift || [];
    for my $aid (@$aids) {
      warn "Resuming backfill for $aid\n";
      prod_backfill($aid);
    }
  }, sub { warn "Failed to query needs_backfill: $_[0]\n" });
});

#
# Graceful shutdown
#

sub _maybe_finish_shutdown {
  # Wait until all in-flight requests (except __accounts__ itself) are done
  for my $name (keys %waiting) {
    next if $name eq '__accounts__';
    return if %{$waiting{$name}};
  }

  # All in-flight requests are done — stop accepting, close idle backends
  $httpd = undef;
  $mgmt = undef;
  for my $name (keys %backend) {
    next if $name eq '__accounts__';
    delete $backend{$name};
    delete $waiting{$name};
  }

  # Flush token touches; exit in the callback
  my $do_exit = sub {
    delete $backend{__accounts__};
    delete $waiting{__accounts__};
    warn "Shutdown complete\n";
    exit 0;
  };

  if (%token_touch) {
    my @entries = map { [$_, @{$token_touch{$_}}] } keys %token_touch;
    %token_touch = ();
    send_backend_request('__accounts__', 'touch_tokens', { tokens => \@entries },
      sub { $do_exit->() },
      sub { $do_exit->() });
  } else {
    $do_exit->();
  }
}

my $shutdown = sub {
  return if $shutting_down;
  $shutting_down = 1;
  warn "Shutting down — draining in-flight requests...\n";

  # Reject new requests on both ports while keeping existing connections alive
  $httpd->reg_cb('' => sub { $_[1]->respond([503, 'shutting down', {}, 'Server shutting down']) });
  $mgmt->reg_cb( '' => sub { $_[1]->respond([503, 'shutting down', {}, 'Server shutting down']) });

  # If nothing is in flight, finish immediately
  _maybe_finish_shutdown();
};

my $sig_term = AnyEvent->signal(signal => 'TERM', cb => $shutdown);
my $sig_int  = AnyEvent->signal(signal => 'INT',  cb => $shutdown);

# Eagerly initialize accounts.sqlite3 before the event loop so all child workers
# see a properly-schemaed DB from the moment they open it (avoids race conditions
# when per-account workers are spawned before the __accounts__ worker runs).
{
  my $_dbh = DBI->connect("dbi:SQLite:dbname=$datadir/accounts.sqlite3");
  _migrate_accounts_db($_dbh);
  $_dbh->disconnect;
}

EV::run();
