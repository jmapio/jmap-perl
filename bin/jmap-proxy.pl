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
use AnyEvent::Socket;
use AnyEvent::Util;
use Cookie::Baker;
use Data::Dumper;
use Data::UUID::LibUUID;
use DBI;
use Encode qw(encode_utf8);
use HTML::GenerateUtil qw(escape_html escape_uri);
use HTTP::Request;
use HTTP::Response;
use IO::Socket::UNIX;
use JSON::XS qw(decode_json);
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
my %backend;   # accountid => [AnyEvent::Handle, cmd_counter]
my %waiting;   # accountid => { cmd_id => [success_cb, error_cb] }

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
        require EV;
        require IO::Socket::SSL;
        require JMAP::API;
        require JMAP::ImapDB;
        require JMAP::DB;
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
    ), 0];

    $backend{$accountid}[0]->push_read(json => mk_json($accountid));
  }

  return $backend{$accountid};
}

sub run_backend_worker {
  my ($sock, $accountid) = @_;

  # This runs in the forked child
  my $hdl = AnyEvent::Handle->new(
    fh => $sock,
    on_error => sub { EV::unloop() },
    on_eof => sub { EV::unloop() },
  );

  # Load the account database
  my $dbh = DBI->connect("dbi:SQLite:dbname=$datadir/accounts.sqlite3");
  my ($email, $type) = $dbh->selectrow_array(
    "SELECT email, type FROM accounts WHERE accountid = ?", {}, $accountid);
  die "No such account: $accountid\n" unless $type;

  my $db;
  if ($type eq 'imap') {
    $db = JMAP::ImapDB->new($accountid);
  }
  else {
    die "Unsupported account type: $type\n";
  }

  my $api = JMAP::API->new($db);

  # Send initial ready signal
  my $change_cb = sub {
    my ($db, $states) = @_;
    eval { $hdl->push_write(json => ['push', $states, 'state']) };
  };
  $db->{change_cb} = $change_cb;

  # Set up idle timeout
  my $timeout;
  my $reset_timeout = sub {
    $timeout = AnyEvent->timer(after => 600, cb => sub {
      warn "SHUTTING DOWN $accountid ON TIMEOUT\n";
      eval { $hdl->push_write(json => ['bye', 'timeout', 'bye']) };
      EV::unloop();
    });
  };
  $reset_timeout->();

  # Process commands
  my $handler;
  $handler = sub {
    my ($h, $request) = @_;
    $reset_timeout->();

    my ($cmd, $args, $tag) = @$request;
    my $t0 = [Time::HiRes::gettimeofday()];

    $in_request = 1;
    my $res = eval {
      if ($cmd eq 'ping') {
        return ['pong', $accountid];
      }
      if ($cmd eq 'getinfo') {
        return ['info', [$email, $type]];
      }
      if ($cmd eq 'upload') {
        my ($aid, $type, $content) = @{$args}{qw(accountId type content)};
        my ($r) = $api->uploadFile($aid || $accountid, $type, $content);
        return ['upload', $r];
      }
      if ($cmd eq 'download') {
        my ($type, $content) = $api->downloadFile($args);
        return ['download', [$type, $content]];
      }
      if ($cmd eq 'raw') {
        my ($type, $content, $filename) = $api->getRawBlob($args);
        return ['raw', [$type, $content, $filename]];
      }
      if ($cmd eq 'jmap') {
        return ['jmap', $api->handle_request($args)];
      }
      if ($cmd eq 'sync') {
        $db->sync_imap();
        return ['sync', $JSON::true];
      }
      if ($cmd eq 'davsync') {
        $db->sync_calendars();
        $db->sync_addressbooks();
        return ['davsync', $JSON::true];
      }
      if ($cmd eq 'delete') {
        $dbh->do("DELETE FROM accounts WHERE accountid = ?", {}, $accountid);
        $db->delete() if $db;
        $hdl->{timer} = AnyEvent->timer(after => 0, cb => sub { EV::unloop() });
        return ['deleted', $JSON::true];
      }
      die "Unknown command: $cmd\n";
    };
    unless ($res) {
      $res = ['error', "$@"];
    }
    if ($db && $db->in_transaction()) {
      $db->rollback();
    }
    $in_request = 0;
    $res->[2] = $tag;
    eval { $hdl->push_write(json => $res) };

    my $elapsed = Time::HiRes::tv_interval($t0);
    warn "HANDLED $cmd ($tag) => ($accountid) in $elapsed\n";

    $h->push_read(json => $handler);
  };

  $hdl->push_read(json => $handler);

  # Also run periodic sync
  my $in_request = 0;
  my $sync_timer = AnyEvent->timer(after => 5, interval => 30, cb => sub {
    return if $in_request;  # don't sync while handling a request
    eval { $db->sync_imap() };
    warn "Sync error for $accountid: $@" if $@;
  });

  EV::run();
}

sub send_backend_request {
  my $accountid = shift;
  my $request = shift;
  my $args = shift;
  my $cb = shift;
  my $errcb = shift;
  my $backend = get_backend($accountid);
  my $cmd = "#" . $backend->[1]++;
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

sub do_jmap {
  my ($httpd, $req) = @_;

  my $uri = $req->url();
  my $path = $uri->path();

  return invalid_request($req) unless $path =~ m{^/jmap/([^/]+)/?$};
  my $accountid = $1;

  return invalid_request($req) unless lc $req->method eq 'post';

  my $content = $req->content;
  my $data = eval { decode_json($content) };
  return invalid_request($req) unless $data;

  $httpd->stop_request();

  send_backend_request($accountid, 'jmap', $data, sub {
    my $result = shift;
    my $body = $json->encode($result);
    warn "JMAP RESPONSE: " . length($body) . " bytes\n";
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

  $httpd->stop_request();

  send_backend_request($accountid, 'upload', { accountId => $accountid, type => $type, content => $content }, sub {
    my $result = shift;
    $req->respond({
      content => ['application/json', $json->encode($result)],
    });
  }, sub {
    my $error = shift;
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
  $TT->process("landing.html", { baseurl => $BASEURL }, \$html)
    || $req->respond([500, 'error', {}, $Template::ERROR]);
  $req->respond({ content => ['text/html', $html] });
}

#
# Start HTTP server
#

my $port = $ENV{JMAP_PORT} || 9000;
my $httpd = AnyEvent::HTTPD->new(port => $port);

$httpd->reg_cb(
  '/jmap'   => \&do_jmap,
  '/upload' => \&do_upload,
  '/raw'    => \&do_raw,
  '/'       => \&do_landing,
);

warn "JMAP proxy listening on port $port\n";
warn "  Data: $datadir\n";
warn "  Base URL: $BASEURL\n";

EV::run();
