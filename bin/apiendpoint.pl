#!/usr/bin/perl -w

use lib '/home/jmap/jmap-perl';
package JMAP::Backend;

#use Mail::IMAPTalk qw(:trace);

use Carp qw(verbose);
use strict;
use warnings;
use AnyEvent;
use AnyEvent::Gmail;
use Mail::IMAPTalk;
use Data::Dumper;
use AnyEvent::HTTPD;
use JMAP::GmailDB;
use JMAP::ImapDB;
use JMAP::DB;
use JMAP::API;
use AnyEvent::Handle;
use AnyEvent::Socket;
use AnyEvent::Util;
use AnyEvent::HTTP;
use EV;
use JSON::XS qw(encode_json decode_json);

use Net::Server::PreFork;

use base qw(Net::Server::PreFork);

# we love globals
my $hdl;
my $db;
my $dbh;
my $accountid;

$0 = '[jmap proxy]';

sub set_accountid {
  $accountid = shift;
  $0 = "[jmap proxy] $accountid";
}

sub handle_getinfo {
  $dbh ||= accountsdb();
  my ($email, $type) = $dbh->selectrow_array("SELECT email,type FROM accounts WHERE accountid = ?", {}, $accountid);
  die "NO SUCH ACCOUNT\n" unless $email;
  return ['info', [$email, $type]];
}

sub getdb {
  return $db if $db;
  die "no accountid" unless $accountid;
  $dbh ||= accountsdb();
  my ($email, $type) = $dbh->selectrow_array("SELECT email,type FROM accounts WHERE accountid = ?", {}, $accountid);
  die "no type" unless $type;
  warn "CONNECTING: $email $type\n";
  if ($type eq 'gmail') {
    $db = JMAP::GmailDB->new($accountid);
  }
  elsif ($type eq 'imap') {
    $db = JMAP::ImapDB->new($accountid);
  }
  else {
    die "Weird type $type";
  }
  $db->{change_cb} = \&change_cb;
  $db->{watcher} = AnyEvent->timer(after => 30, interval => 30, cb => sub {
    # check if there's more work to do on the account...
    eval {
      $db->begin();
      $db->backfill();
      $db->commit();
    };
  });
  return $db;
}

sub process_request {
  my $server = shift;

  close STDIN;
  close STDOUT;
  $hdl = AnyEvent::Handle->new(
    fh => $server->{server}{client},
    on_error => sub {
      my ($hdl, $fatal, $msg) = @_;
      $hdl->destroy;
      EV::unloop;
    },
    on_disconnect => sub {
      my ($hdl, $fatal, $msg) = @_;
      $hdl->destroy;
      EV::unloop;
    },
  );

  # send some request line
  $hdl->push_read(line => sub {
    my $handle = shift;
    set_accountid(shift);
    warn "Connected $accountid\n";
    $handle->push_read(json => mk_handler($accountid));
  });

  EV::run;
  exit 0;
}

JMAP::Backend->run(host => '127.0.0.1', port => 5000);

sub change_cb {
  my $db = shift;
  my $state = shift;

  my $data = {
    clientId => undef,
    accountStates => {
      $db->accountid() => {
        messages => "$state",
        threads => "$state",
        mailboxes => "$state",
      },
    },
  };

  $hdl->push_write(json => ['push', $data]) if $hdl;
}

sub handle_ping {
  return ['pong', $accountid];
}

sub handle_getstate {
  my $db = shift;
  my $cmd = shift;

  $db->begin();
  my $user = $db->get_user();
  $db->commit();
  die "Failed to get user" unless $user;
  my $state = "$user->{jhighestmodseq}";

  my $data = {
    clientId => undef,
    accountStates => {
      $db->accountid() => {
        mailState => "$state",
      },
    },
  };

  return ['state', $data];
}

sub mk_handler {
  my ($db) = @_;

  $hdl->{killer} = AnyEvent->timer(after => 600, cb => sub {
    warn "SHUTTING DOWN $accountid ON TIMEOUT\n";
    $hdl->push_write(json => ['bye']);
    $hdl->push_shutdown();
    undef $hdl;
    EV::unloop;
  });

  return sub {
    my ($hdl, $json) = @_;

    # make sure we have a connection

    my ($cmd, $args, $tag) = @$json;
    my $res = eval {
      if ($cmd eq 'ping') {
        return handle_ping();
      }
      if ($cmd eq 'upload') {
        return handle_upload(getdb(), $args, $tag);
      }
      if ($cmd eq 'download') {
        return handle_download(getdb(), $args, $tag);
      }
      if ($cmd eq 'raw') {
        return handle_raw(getdb(), $args, $tag);
      }
      if ($cmd eq 'jmap') {
        return handle_jmap(getdb(), $args, $tag);
      }
      if ($cmd eq 'cb_google') {
        return handle_cb_google($args);
      }
      if ($cmd eq 'signup') {
        return handle_signup($args);
      }
      if ($cmd eq 'delete') {
        return handle_delete();
      }
      if ($cmd eq 'gettoken') {
        return handle_gettoken(getdb(), $args, $tag);
      }
      if ($cmd eq 'getstate') {
        return handle_getstate(getdb(), $args, $tag);
      }
      if ($cmd eq 'sync') {
        return handle_sync(getdb(), $args, $tag);
      }
      if ($cmd eq 'getinfo') {
        return handle_getinfo();
      }
      die "Unknown command $cmd";
    };
    unless ($res) {
      $res = ['error', "$@"]
    }
    if ($res->[0]) {
      $res->[2] = $tag;
      $hdl->push_write(json => $res) if $res->[0];
      warn "HANDLED $cmd ($tag) => $res->[0] ($accountid)\n" ;
      if ($res->[0] eq 'error') {
	warn Dumper($res);
      }
    }
    $hdl->push_read(json => mk_handler($db));
  };
}

sub handle_sync {
  my $db = shift;
  $db->begin();
  $db->sync_imap();
  $db->commit();
  return ['sync', $JSON::true];
}

sub handle_davsync {
  my $db = shift;
  $db->begin();
  $db->sync_calendars();
  $db->sync_addressbooks();
  $db->commit();
  return ['sync', $JSON::true];
}

sub accountsdb {
  my $dbh = DBI->connect("dbi:SQLite:dbname=/home/jmap/data/accounts.sqlite3");
  $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS accounts (
  email TEXT PRIMARY KEY,
  accountid TEXT,
  type TEXT
);
EOF
  return $dbh;
}

sub handle_cb_google {
  my $code = shift;

  my $O = JMAP::GmailDB::O();
  die "NO ACCESS CODE PROVIDED (did you hit cancel?)\n" unless $code;
  my $gmaildata = $O->finish($code);

  my $access_token = $gmaildata->{access_token};
  die "ACCESS TOKEN FAILED\n" unless $access_token;

  my $ua = HTTP::Tiny->new;
  my $res = $ua->get(q{https://www.googleapis.com/userinfo/v2/me}, {
    headers => {
        authorization => "Bearer $access_token",
    }
  });
  die "USER INFO LOOKUP FAILED" unless $res->{success};
  my $data = decode_json($res->{content});

  my $email = $data->{email};

  my $dbh = accountsdb();
  my ($existing, $type) = $dbh->selectrow_array("SELECT accountid,type FROM accounts WHERE email = ?", {}, $email);
  if ($existing) {
    set_accountid($existing);
  }
  else {
    $dbh->do("INSERT INTO accounts (email, accountid, type) VALUES (?, ?, ?)", {}, $email, $accountid, 'gmail');
  }

  getdb();
  $db->begin();
  $db->setuser($email, $gmaildata->{refresh_token}, $data->{name}, $data->{picture});
  $db->commit();
  $db->begin();
  $db->firstsync();
  $db->commit();

  return ['registered', [$accountid, $email]];
}

sub handle_signup {
  my $detail = shift;

  my $imap = Mail::IMAPTalk->new(
   Server => $detail->[0],
   Port => 993,
   UseSSL => 1,
   UseBlocking => 1,
  );
  die "UNABLE TO CONNECT to $detail->[0]\n" unless $imap;

  my $ok = $imap->login($detail->[1], $detail->[2]);
  die "LOGIN FAILED FOR $detail->[1] on $detail->[0]" unless $ok;
  my $capa = $imap->capability();
  $imap->logout();

  die "THIS PROXY REQUIRES A SERVER THAT SUPPORTS CONDSTORE: $detail->[0]" unless $capa->{condstore};

  my $dbh = accountsdb();
  my ($existing, $type) = $dbh->selectrow_array("SELECT accountid, type FROM accounts WHERE email = ?", {}, $detail->[1]);
  if ($existing) {
    set_accountid($existing);
  }
  else {
    $dbh->do("INSERT INTO accounts (email, accountid, type) VALUES (?, ?, ?)", {}, $detail->[1], $accountid, 'imap');
  }
  getdb();
  $db->begin();
  $db->setuser(@$detail);
  $db->commit();
  $db->begin();
  $db->firstsync();
  $db->commit();

  return ['signedup', [$accountid, $detail->[1]]];
}

sub handle_delete {
  my $dbh = accountsdb();
  $dbh->do("DELETE FROM accounts WHERE accountid = ?", {}, $accountid);
  $db->delete() if $db;
  $hdl->{timer} = AnyEvent->timer(after => 0, cb => sub { undef $hdl; EV::unloop; });
  return ['deleted', $accountid];
}

sub handle_gettoken {
  my $db = shift;

  my $data = $db->access_token();
  return ['token', $data];
}

sub handle_upload {
  my ($db, $req) = @_;
  my ($type, $content) = @$req;

  $db->begin();
  my $api = JMAP::API->new($db);
  my ($res) = $api->uploadFile($type, $content);
  $db->commit();

  return ['upload', $res];
}

sub handle_download {
  my ($db, $id) = @_;

  $db->begin();
  my $api = JMAP::API->new($db);
  my ($type, $content) = $api->downloadFile($id);
  $db->commit();

  return ['download', [$type, $content]];
}

sub handle_raw {
  my ($db, $req) = @_;

  $db->begin();
  my $api = JMAP::API->new($db);
  my ($type, $content, $filename) = $api->getRawMessage($req);
  $db->commit();

  return ['raw', [$type, $content, $filename]];
}

sub handle_jmap {
  my ($db, $request) = @_;

  my @res;
  # need to keep the API object around for the entire request for idmap purposes
  my $api = JMAP::API->new($db);
  foreach my $item (@$request) {
    my ($command, $args, $tag) = @$item;
    my @items;
    my $FuncRef = $api->can($command);
    if ($FuncRef) {
      $db->begin();
      my $res = eval { @items = $api->$command($args, $tag); return 1 };
      if ($res) {
        $db->commit();
      }
      else {
        my $error = $@;
        @items = ['error', { type => 'serverError', description => $error }];
        $db->rollback();
      }
    }
    else {
      @items = ['error', { type => 'unknownMethod' }];
    }
    $_->[2] = $tag for @items;
    push @res, @items;
  }

  return ['jmap', \@res];
}
