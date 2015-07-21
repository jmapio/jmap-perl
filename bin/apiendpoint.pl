#!/usr/bin/perl -w

use lib '/home/jmap/jmap-perl';
package JMAP::Backend;

use Mail::IMAPTalk qw(:trace);

# stuff complains otherwise - twice for luck
use IO::Socket::SSL;
$IO::Socket::SSL::DEBUG = 0;
$IO::Socket::SSL::DEBUG = 0;

use Carp qw(verbose);
use strict;
use warnings;
use AnyEvent;
use AnyEvent::Gmail;
use Mail::IMAPTalk;
use Data::Dumper;
use AnyEvent::HTTPD;
use JMAP::Sync::Gmail;
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

use Net::Server::Fork;

use base qw(Net::Server::Fork);

# we love globals
my $hdl;
my $db;
my $dbh;
my $accountid;

$0 = '[jmap proxy]';

sub set_accountid {
  $accountid = shift;
  $0 = "[jmap proxy] $accountid";
  $accountid =~ s/:.*//; # strip section splitter
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
  die "no type for $accountid" unless $type;
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
      warn "SHUTDOWN ON ERROR $accountid";
      $hdl->destroy;
      undef $hdl;
      EV::unloop;
    },
    on_disconnect => sub {
      my ($hdl, $fatal, $msg) = @_;
      warn "SHUTDOWN ON DISCONNECT $accountid";
      $hdl->destroy;
      undef $hdl;
      EV::unloop;
    },
    on_shutdown => sub {
      undef $hdl;
      EV::unloop;
    }
  );

  # send some request line
  $hdl->push_read(line => sub {
    my $handle = shift;
    set_accountid(shift);
    warn "Connected $accountid\n";
    $handle->push_read(json => mk_handler(1));
  });

  EV::run;
  exit 0;
}

JMAP::Backend->run(host => '127.0.0.1', port => 5000);

sub change_cb {
  my $db = shift;
  my $states = shift;

  my $data = {
    changed => {
      $db->accountid() => $states,
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
  die "Failed to get user" unless $user;
  my $state = "$user->{jhighestmodseq}";
  $db->commit();

  my %map;
  foreach my $key (keys %$user) {
    next unless $key =~ m/^jstate(.*)/;
    $map{$1} = $user->{$key} || "1";
  }

  my $data = {
    changed => {
      $db->accountid() => \%map,
    },
  };

  return ['state', $data];
}

sub mk_handler {
  my ($n) = @_;

  $hdl->{killer} = AnyEvent->timer(after => 600, cb => sub {
    warn "SHUTTING DOWN $accountid ON TIMEOUT\n";
    $hdl->push_write(json => ['bye']);
    $hdl->push_shutdown();
    undef $hdl;
    EV::unloop;
  });

  return sub {
    my ($hdl, $json) = @_;
    $hdl->push_read(json => mk_handler($n+1));

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
      if ($cmd eq 'syncall') {
        return handle_syncall(getdb(), $args, $tag);
      }
      if ($cmd eq 'davsync') {
        return handle_davsync(getdb(), $args, $tag);
      }
      if ($cmd eq 'backfill') {
        return handle_backfill(getdb(), $args, $tag);
      }
      if ($cmd eq 'getinfo') {
        return handle_getinfo();
      }
      die "Unknown command $cmd";
    };
    unless ($res) {
      $res = ['error', "$@"]
    }
    if ($db and $db->in_transaction()) {
      $res = ['error', "STILL IN TRANSACTION " . Dumper($res, $args, $tag)]
    }
    $res->[2] = $tag;
    $hdl->push_write(json => $res) if $res->[0];
    warn "HANDLED $cmd ($tag) => $res->[0] ($accountid)\n" ;
    if ($res->[0] eq 'error') {
      warn Dumper($res);
      warn "DIED AFTER COMMAND $n";
      # this process won't handle any more connections
      $hdl->push_shutdown();
    }
  };
}

sub handle_sync {
  my $db = shift;
  $db->sync_imap();
  return ['sync', $JSON::true];
}

sub handle_syncall {
  my $db = shift;
  $db->sync_folders();
  $db->sync_imap();
  $db->sync_addressbooks();
  $db->sync_calendars();
  return ['syncall', $JSON::true];
}

sub handle_backfill {
  my $db = shift;
  my $res = $db->backfill();
  return ['sync', $res ? $JSON::true : $JSON::false];
}

sub handle_davsync {
  my $db = shift;
  $db->sync_calendars();
  $db->sync_addressbooks();
  return ['davsync', $JSON::true];
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

  my $O = JMAP::Sync::Gmail::O();
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
  #$db->setuser(username => $email, password => $gmaildata->{refresh_token}, email => $data->{name}, picture => $data->{picture});
  $db->setuser(
    username => $email,
    password => $gmaildata->{refresh_token},
    imapHost => 'imap.gmail.com',
    imapPort => '993',
    imapSSL => 1,
    smtpHost => 'smtp.gmail.com',
    smtpPort => 465,
    smtpSSL => 1,
    caldavURL => "https://apidata.googleusercontent.com/caldav/v2",
    # still broken
    #carddavURL => "https://www.googleapis.com/.well-known/carddav",
  );
  $db->firstsync();

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

  my $dbh = accountsdb();
  my ($existing, $type) = $dbh->selectrow_array("SELECT accountid, type FROM accounts WHERE email = ?", {}, $detail->[1]);
  if ($existing) {
    set_accountid($existing);
  }
  else {
    $dbh->do("INSERT INTO accounts (email, accountid, type) VALUES (?, ?, ?)", {}, $detail->[1], $accountid, 'imap');
  }
  getdb();
  $db->setuser(
    username => $detail->[1],
    password => $detail->[2],
    imapHost => $detail->[0],
    imapPort => 993,
    imapSSL => 1,
    smtpHost => $detail->[0],
    smtpPort => 465,
    smtpSSL => 1,
  );
  $db->firstsync();

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

  my $api = JMAP::API->new($db);
  my ($res) = $api->uploadFile($type, $content);

  return ['upload', $res];
}

sub handle_download {
  my ($db, $id) = @_;

  my $api = JMAP::API->new($db);
  my ($type, $content) = $api->downloadFile($id);

  return ['download', [$type, $content]];
}

sub handle_raw {
  my ($db, $req) = @_;

  my $api = JMAP::API->new($db);
  my ($type, $content, $filename) = $api->getRawMessage($req);

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
    warn "JMAP CMD $command";
    if ($FuncRef) {
      @items = eval { $api->$command($args, $tag) };
      if ($@) {
        @items = ['error', { type => "serverError", message => "$@" }];
	eval { $api->rollback() };
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
