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
use Digest::SHA qw(sha1_hex);
use Encode qw(encode_utf8);
use File::Temp ();
use HTML::GenerateUtil qw(escape_html escape_uri);
use HTTP::Request;
use HTTP::Response;
use JSON;
use JSON::XS qw(decode_json);
use MIME::Base64 qw(decode_base64);
use MIME::Base64::URLSafe;
use POSIX qw(:sys_wait_h);
use Socket;
use Template;
use URI;

# Backend modules (loaded in child after fork)
# use JMAP::API; use JMAP::ImapDB; etc.

my $BASEURL = $ENV{BASEURL} || 'http://localhost:' . ($ENV{JMAP_PORT} || 9000);
my $jmaphome = $ENV{JMAP_HOME} || '/home/jmap/jmap-perl';
my $datadir = $ENV{JMAP_DATADIR} || '/data';

mkdir "$datadir/tmp" unless -d "$datadir/tmp";

my $TT = Template->new(INCLUDE_PATH => "$jmaphome/htdocs");
my $json = JSON::XS->new->utf8->canonical->pretty();

# Reap zombie children
my $child_watcher = AnyEvent->signal(signal => 'CHLD', cb => sub {
  while ((my $pid = waitpid(-1, WNOHANG)) > 0) {
    warn "Reaped child $pid\n";
  }
});

#
# Backend connection management
#
my %backend;   # accountid => [AnyEvent::Handle, cmd_counter, pid, last_active]
my %waiting;   # accountid => { cmd_id => [success_cb, error_cb] }
my $start_time = time();

sub mk_json {
  my $accountid = shift;
  return sub {
    my ($hdl, $res) = @_;
    if ($res->[0] eq 'push') {
      # PushEvent - TODO
    }
    elsif ($res->[0] eq 'bye') {
      warn "Backend closing $accountid\n";
      delete $backend{$accountid};
    }
    elsif ($waiting{$accountid}{$res->[2]}) {
      if ($res->[0] eq 'error') {
        $waiting{$accountid}{$res->[2]}[1]->($res->[1]);
        warn "Backend error on $accountid: $res->[1]\n";
        delete $backend{$accountid};
      }
      else {
        $backend{$accountid}[3] = time() if $backend{$accountid};
        $waiting{$accountid}{$res->[2]}[0]->($res->[1]);
      }
      delete $waiting{$accountid}{$res->[2]};
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

  my $accountid = $name;
  $0 = "[jmap worker] $accountid";

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
    } else {
      die "Unsupported account type: $type\n";
    }
    $api = JMAP::API->new($db);
    $db->{change_cb} = sub {
      my ($db, $states) = @_;
      eval { $write_json->(['push', $states, 'state']) };
    };
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

      # Initialize DB for commands that need it (not signup — it creates the account first)
      $init_db->() if $cmd ne 'signup' && !$db;

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
        elsif (!$detail->{imapHost}) {
          # DNS SRV lookup
          my $resolver = Net::DNS::Resolver->new;
          my $domain = $detail->{username};
          $domain =~ s/.*\@//;

          my $srv_lookup = sub {
            my ($name) = @_;
            my $reply = $resolver->query($name, 'SRV') or return ();
            my @rr = grep { $_->type eq 'SRV' && $_->target ne '.' && $_->port > 0 } $reply->answer;
            return @rr;
          };

          for my $try (["_imaps._tcp.$domain", 'imapHost', 'imapPort', 2],
                       ["_imap._tcp.$domain",  'imapHost', 'imapPort', 3]) {
            my @d = $srv_lookup->($try->[0]);
            if (@d) {
              $detail->{$try->[1]} = $d[0]->target;
              $detail->{$try->[2]} = $d[0]->port;
              $detail->{imapSSL} = $try->[3];
              last;
            }
          }

          for my $try (["_submissions._tcp.$domain",  'smtpHost', 'smtpPort', 2],
                       ["_smtps._tcp.$domain",        'smtpHost', 'smtpPort', 2],
                       ["_submission._tcp.$domain",    'smtpHost', 'smtpPort', 3]) {
            my @d = $srv_lookup->($try->[0]);
            if (@d) {
              $detail->{$try->[1]} = $d[0]->target;
              $detail->{$try->[2]} = $d[0]->port;
              $detail->{smtpSSL} = $try->[3];
              last;
            }
          }

          for my $try (["_caldavs._tcp.$domain",  'caldavURL',  'https', 443],
                       ["_caldav._tcp.$domain",   'caldavURL',  'http',  80],
                       ["_carddavs._tcp.$domain", 'carddavURL', 'https', 443],
                       ["_carddav._tcp.$domain",  'carddavURL', 'http',  80]) {
            my @d = $srv_lookup->($try->[0]);
            if (@d) {
              my $host = $d[0]->target;
              my $port = $d[0]->port;
              my $url = "$try->[2]://$host";
              $url .= ":$port" unless $port == $try->[3];
              $detail->{$try->[1]} = $url;
            }
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
        my ($r) = $api->uploadFile($aid || $accountid, $utype, { file => $file });
        return ['upload', $r];
      }
      if ($cmd eq 'download') {
        my ($dtype, $content) = $api->downloadFile($args->{blobId});
        return ['download', [$dtype, $content]];
      }
      if ($cmd eq 'raw') {
        my $selector = "$args->{blobId}/$args->{name}";
        my ($rtype, $content, $filename) = $api->getRawBlob($selector);
        return ['raw', [$rtype, $content, $filename]];
      }
      if ($cmd eq 'jmap') {
        my $result = $api->handle_request($args);
        # Add sessionState: checksum of sorted accountIds in pool (RFC 8620)
        my $poolid = $dbh->selectrow_array(
          "SELECT poolid FROM accounts WHERE accountid = ?", {}, $accountid) || $accountid;
        my $aids = $dbh->selectcol_arrayref(
          "SELECT accountid FROM accounts WHERE poolid = ? ORDER BY accountid", {}, $poolid);
        $result->{sessionState} = Digest::SHA::sha1_hex(join(',', @$aids));
        return ['jmap', $result];
      }
      if ($cmd eq 'sync') {
        $db->sync_folders();
        $db->sync_imap();
        return ['sync', $JSON::true];
      }
      if ($cmd eq 'davsync') {
        $db->sync_calendars();
        $db->sync_addressbooks();
        return ['davsync', $JSON::true];
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

sub run_accounts_worker {
  my ($sock) = @_;

  $0 = "[jmap accounts]";

  my ($read_json, $write_json) = _make_json_io($sock);

  my $dbh = DBI->connect("dbi:SQLite:dbname=$datadir/accounts.sqlite3");
  $dbh->do("CREATE TABLE IF NOT EXISTS accounts (email TEXT PRIMARY KEY, accountid TEXT, type TEXT, poolid TEXT)");
  $dbh->do("CREATE TABLE IF NOT EXISTS tokens (token TEXT PRIMARY KEY, accountid TEXT NOT NULL)");
  # Backfill poolid for any rows that don't have it
  $dbh->do("UPDATE accounts SET poolid = accountid WHERE poolid IS NULL");

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
        $dbh->do("INSERT OR REPLACE INTO accounts (email, accountid, type, poolid) VALUES (?, ?, ?, ?)",
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
        $dbh->do("INSERT OR REPLACE INTO tokens (token, accountid) VALUES (?, ?)", {}, $token, $aid);
        return ['create_token', { token => $token, accountid => $aid }];
      }

      if ($cmd eq 'resolve_token') {
        my $token = $args->{token};
        my $row = $dbh->selectrow_hashref(
          "SELECT accountid FROM tokens WHERE token = ?", {}, $token);
        return ['resolve_token', $row ? $row->{accountid} : undef];
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

      if ($cmd eq 'delete_account') {
        my $aid = $args->{accountid};
        $dbh->do("DELETE FROM accounts WHERE accountid = ?", {}, $aid);
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
      my $primary_aid;
      for my $a (@{$pool->{accounts} || []}) {
        $accounts->{$a->{accountid}} = {
          name => $a->{email} || $a->{accountid},
          isPersonal => ($a->{accountid} eq $auth_aid ? JSON::true : JSON::false),
          isReadOnly => JSON::false,
          accountCapabilities => {
            'urn:ietf:params:jmap:mail' => {},
            'urn:ietf:params:jmap:submission' => {
              maxDelayedSend => 0,
            },
            'urn:ietf:params:jmap:quota' => {},
          },
        };
        $primary_aid //= $a->{accountid};
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
          'urn:ietf:params:jmap:quota' => {},
        },
        accounts => $accounts,
        primaryAccounts => {
          'urn:ietf:params:jmap:mail' => $primary_aid,
          'urn:ietf:params:jmap:submission' => $primary_aid,
        },
        username => ($pool->{accounts} && $pool->{accounts}[0] ? $pool->{accounts}[0]{email} : ''),
        apiUrl => "$BASEURL/jmap",
        downloadUrl => "$BASEURL/raw/{accountId}/{blobId}/{name}",
        uploadUrl => "$BASEURL/upload/{accountId}",
        eventSourceUrl => "$BASEURL/eventsource?types={types}&closeafter={closeafter}&ping={ping}",
        state => "$pool->{poolid}:" . time(),
      };

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

sub do_jmap {
  my ($httpd, $req) = @_;

  my $uri = $req->url();
  my $path = $uri->path();

  return invalid_request($req) unless lc $req->method eq 'post';

  my $content = $req->content;
  my $data = eval { decode_json($content) };
  return invalid_request($req) unless $data;

  # Legacy: /jmap/{accountid} — accountid in URL is the credential
  if ($path =~ m{^/jmap/([^/]+)/?$}) {
    my $accountid = $1;
    $httpd->stop_request();
    _do_jmap_request($req, $accountid, $data);
    return;
  }

  # Standard: POST /jmap with auth header/cookie
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

  my $uri = $req->url();
  my $path = $uri->path();

  return invalid_request($req) unless $path =~ m{^/upload/([^/]+)/?$};
  my $accountid = $1;

  return invalid_request($req) unless lc $req->method eq 'post';

  my $type = $req->headers->{'content-type'} || 'application/octet-stream';
  my $content = $req->content;

  # Write upload content to tempfile to avoid passing binary through JSON socketpair
  my $tmp = File::Temp->new(DIR => "$datadir/tmp", UNLINK => 0);
  print $tmp $content;
  close $tmp;
  my $tmpfile = $tmp->filename;

  $httpd->stop_request();

  send_backend_request($accountid, 'upload', { accountId => $accountid, type => $type, file => $tmpfile }, sub {
    my $result = shift;
    $req->respond({
      content => ['application/json', $json->encode($result)],
    });
  }, sub {
    my $error = shift;
    unlink $tmpfile;
    $req->respond([500, 'error', {}, "upload failed: $error"]);
  });
}

sub do_raw {
  my ($httpd, $req) = @_;

  my $uri = $req->url();
  my $path = $uri->path();

  return invalid_request($req) unless $path =~ m{^/raw/([^/]+)/([^/]+)/(.+)$};
  my ($accountid, $blobid, $name) = ($1, $2, $3);

  $httpd->stop_request();

  send_backend_request($accountid, 'download', { blobId => $blobid, name => $name }, sub {
    my $result = shift;
    my $type = $result->[0] || 'application/octet-stream';
    $req->respond([200, 'ok', { 'Content-Type' => $type }, $result->[1]]);
  }, sub {
    my $error = shift;
    $req->respond([404, 'not found', {}, "not found"]);
  });
}

sub do_landing {
  my ($httpd, $req) = @_;
  my $html = '';
  $TT->process("index.html", { baseurl => $BASEURL }, \$html)
    || return $req->respond([500, 'error', {}, $Template::ERROR]);
  $req->respond({ content => ['text/html', $html] });
}

sub do_static {
  my ($httpd, $req) = @_;
  my $path = $req->url->path;
  $path =~ s{^/}{};
  # Only serve known safe extensions
  return not_found($req) unless $path =~ /\.(css|js|html|png|ico)$/;
  my $file = "$jmaphome/htdocs/$path";
  return not_found($req) unless -f $file;
  my %types = (css => 'text/css', js => 'text/javascript', html => 'text/html',
               png => 'image/png', ico => 'image/x-icon');
  my ($ext) = $path =~ /\.(\w+)$/;
  open my $fh, '<', $file or return not_found($req);
  local $/;
  my $content = <$fh>;
  close $fh;
  $req->respond([200, 'ok', { 'Content-Type' => $types{$ext} || 'application/octet-stream' }, $content]);
}

sub _generate_token {
  open my $fh, '<', '/dev/urandom' or die "Cannot open /dev/urandom: $!";
  my $bytes;
  read $fh, $bytes, 32;  # 256 bits
  close $fh;
  return unpack('H*', $bytes);
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

sub _check_cache {
  my ($key) = @_;
  if (my $cached = $auth_cache{$key}) {
    if ($cached->[1] > time()) {
      return $cached->[0];
    }
    delete $auth_cache{$key};
  }
  return undef;
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
    my $cached = _check_cache("bearer:$token");
    if ($cached) { $cb->($cached); return; }
    $httpd->stop_request();
    send_backend_request('__accounts__', 'resolve_token', { token => $token }, sub {
      my $aid = shift;
      if ($aid) {
        $auth_cache{"bearer:$token"} = [$aid, time() + $AUTH_CACHE_TTL];
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
    my $cached = _check_cache("bearer:$token");
    if ($cached) { $cb->($cached); return; }
    $httpd->stop_request();
    send_backend_request('__accounts__', 'resolve_token', { token => $token }, sub {
      my $aid = shift;
      if ($aid) {
        $auth_cache{"bearer:$token"} = [$aid, time() + $AUTH_CACHE_TTL];
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

sub do_signup {
  my ($httpd, $req) = @_;

  return invalid_request($req) unless lc $req->method eq 'post';

  my %opts;
  for my $key (qw(username password imapHost imapPort imapSSL smtpHost smtpPort smtpSSL caldavURL carddavURL force)) {
    $opts{$key} = $req->parm($key);
  }

  return invalid_request($req) unless $opts{username} && $opts{password};

  # If logged in, new account joins the existing pool
  # Use sync cache check — if not cached, pool join will be skipped (acceptable)
  my $auth_aid = _get_auth_accountid($req);
  $opts{poolid} = $auth_aid if $auth_aid;

  my $accountid = new_uuid_string();

  $httpd->stop_request();

  # Step 1: send signup to a per-account child for DNS resolution + IMAP test
  send_backend_request($accountid, 'signup', \%opts, sub {
    my $result = shift;

    if ($result->[0] eq 'continue') {
      # Need user confirmation — show signup.html with resolved details
      my $html = '';
      $TT->process("signup.html", $result->[1], \$html)
        || return $req->respond([500, 'error', {}, $Template::ERROR]);
      # This child was just for DNS/IMAP test, clean it up
      delete $backend{$accountid};
      $req->respond({ content => ['text/html', $html] });
      return;
    }

    if ($result->[0] eq 'done') {
      my ($final_accountid, $username) = @{$result}[1, 2];
      # Trigger background sync
      send_backend_request($final_accountid, 'sync', {});
      # Create a token for the cookie
      my $token = _generate_token();
      send_backend_request('__accounts__', 'create_token',
        { token => $token, accountid => $final_accountid }, sub {
        $auth_cache{"bearer:$token"} = [$final_accountid, time() + $AUTH_CACHE_TTL];
        my $cookie = bake_cookie("jmap_proxy", {
          value => $token,
          path => '/',
          expires => '+3M',
        });
        $req->respond([301, 'redirected',
          { 'Set-Cookie' => $cookie, Location => "$BASEURL/accounts" },
          "Redirected"]);
      }, sub {
        $req->respond([500, 'error', {}, 'failed to create session']);
      });
      # Clean up temp child if a different accountid was used
      delete $backend{$accountid} unless $final_accountid eq $accountid;
      return;
    }
  }, sub {
    my $err = shift;
    delete $backend{$accountid};
    if ($auth_aid) {
      # User was logged in — redirect back to accounts page
      $req->respond([301, 'redirected', { Location => "$BASEURL/accounts" }, "Redirected"]);
    } else {
      my $html = '';
      $TT->process("index.html", { baseurl => $BASEURL, error => "$err" }, \$html)
        || return $req->respond([500, 'error', {}, $Template::ERROR]);
      $req->respond({ content => ['text/html', $html] });
    }
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
  send_backend_request('__accounts__', 'get_pool', { accountid => $auth_aid }, sub {
    my $pool = shift;
    my $html = '';
    my $cookies = crush_cookie($req->headers->{cookie} || '');
    $TT->process("accounts.html", {
      baseurl  => $BASEURL,
      auth_aid => $auth_aid,
      accounts => $pool->{accounts} || [],
      token    => $cookies->{jmap_proxy},
    }, \$html) || return $req->respond([500, 'error', {}, $Template::ERROR]);
    $req->respond([200, 'ok', { 'Content-Type' => 'text/html; charset=utf-8' }, $html]);
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

#
# Start HTTP server
#

my $port = $ENV{JMAP_PORT} || 9000;
my $httpd = AnyEvent::HTTPD->new(port => $port);

$httpd->reg_cb(
  '/.well-known' => \&do_wellknown,
  '/session'     => \&do_session,
  '/jmap'        => \&do_jmap,
  '/upload'      => \&do_upload,
  '/raw'         => \&do_raw,
  '/signup'      => \&do_signup,
  '/accounts'    => \&do_accounts,
  '/logout'      => \&do_logout,
  '/main.css'    => \&do_static,
  '/'            => \&do_landing,
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

    # Step 1: Create account in accounts DB via __accounts__ child
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

$mgmt->reg_cb(
  '/healthz' => \&mgmt_healthz,
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
# Graceful shutdown
#
my $shutting_down = 0;

my $shutdown = sub {
  return if $shutting_down;
  $shutting_down = 1;
  warn "Shutting down...\n";

  # Stop accepting new connections
  $httpd = undef;
  $mgmt = undef;

  # Close all backend children (they'll see EOF and exit)
  for my $name (keys %backend) {
    warn "Closing backend $name\n";
    delete $backend{$name};
    delete $waiting{$name};
  }

  # Give children a moment to exit, then stop event loop
  my $exit_timer; $exit_timer = AnyEvent->timer(after => 2, cb => sub {
    undef $exit_timer;
    warn "Shutdown complete\n";
    exit 0;
  });
};

my $sig_term = AnyEvent->signal(signal => 'TERM', cb => $shutdown);
my $sig_int  = AnyEvent->signal(signal => 'INT',  cb => $shutdown);

EV::run();
