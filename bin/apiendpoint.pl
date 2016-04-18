#!/usr/bin/perl -w

use lib '/home/jmap/jmap-perl';
package JMAP::Backend;

#use Mail::IMAPTalk qw(:trace);

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
use JMAP::Sync::AOL;
use JMAP::Sync::Gmail;
use JMAP::GmailDB;
use JMAP::AOLDB;
use JMAP::ImapDB;
use JMAP::DB;
use JMAP::API;
use AnyEvent::Handle;
use AnyEvent::Socket;
use AnyEvent::Util;
use AnyEvent::HTTP;
use EV;
use JSON::XS qw(decode_json);
use Net::DNS;
use Net::DNS::Resolver;

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
  die "Account $accountid does not exist, please re-create\n" unless $type;
  warn "CONNECTING: $email $type\n";
  if ($type eq 'gmail') {
    $db = JMAP::GmailDB->new($accountid);
  }
  elsif ($type eq 'aol') {
    $db = JMAP::AOLDB->new($accountid);
  }
  elsif ($type eq 'imap') {
    $db = JMAP::ImapDB->new($accountid);
  }
  else {
    die "Weird type $type for $accountid";
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
  $db->commit();

  die "Failed to get user" unless $user;
  my $state = "$user->{jhighestmodseq}";

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
      if ($cmd eq 'cb_aol') {
        return handle_cb_aol($args);
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
      $db->rollback();
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
  $db->firstsync();
  $db->sync_folders();
  $db->sync_imap();
  $db->sync_addressbooks();
  $db->sync_calendars();
  return ['syncall', $JSON::true];
}

sub handle_backfill {
  my $db = shift;
  my $res = $db->backfill();
  return ['backfill', $res ? $JSON::true : $JSON::false];
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

sub handle_cb_aol {
  my $code = shift;

  my $O = JMAP::Sync::AOL::O();
  die "NO ACCESS CODE PROVIDED (did you hit cancel?)\n" unless $code;
  my $aoldata = $O->finish($code);

  my $access_token = $aoldata->{access_token};
  die "ACCESS TOKEN FAILED\n" unless $access_token;

  my $ua = HTTP::Tiny->new;
  my $res = $ua->get(q{https://api.screenname.aol.com/auth/getUserData?f=json&attribute=email}, {
    headers => {
        authorization => "Bearer $access_token",
    }
  });
  die "USER INFO LOOKUP FAILED" unless $res->{success};
  # {"response": {"statusCode": 200, "data": {"userData": {"loginId": "brongondwana", "lastAuth": "1452795114000", "attributes": {"email": "brongondwana@aol.com"}, "md5Verified": false, "displayName": "Bron Gondwana", "OPENAUTH_LOGIN_TYPE": "OAUTH"}}, "statusText": "OK"}}
  my $data = decode_json($res->{content});

  # yep, it's hiding in here
  my $email = $data->{response}{data}{userData}{attributes}{email};

  my $dbh = accountsdb();
  my ($existing, $type) = $dbh->selectrow_array("SELECT accountid,type FROM accounts WHERE email = ?", {}, $email);
  if ($existing) {
    set_accountid($existing);
  }
  else {
    $dbh->do("INSERT INTO accounts (email, accountid, type) VALUES (?, ?, ?)", {}, $email, $accountid, 'aol');
  }

  getdb();
  $db->setuser({
    username => $email,
    password => $aoldata->{refresh_token},
    imapHost => 'imap.aol.com',
    imapPort => '993',
    imapSSL => 2,
    smtpHost => 'smtp.aol.com',
    smtpPort => 465,
    smtpSSL => 2,
    caldavURL => "https://caldav.aol.com/.well-known/caldav",
    carddavURL => "https://carddav.aol.com/.well-known/carddav",
  }, { picture => $data->{picture} });
  $db->firstsync();

  return ['registered', [$accountid, $email]];
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
  $db->setuser({
    username => $email,
    password => $gmaildata->{refresh_token},
    imapHost => 'imap.gmail.com',
    imapPort => '993',
    imapSSL => 2,
    smtpHost => 'smtp.gmail.com',
    smtpPort => 465,
    smtpSSL => 2,
    caldavURL => "https://apidata.googleusercontent.com/caldav/v2",
    carddavURL => "https://www.googleapis.com/.well-known/carddav",
  }, { picture => $data->{picture} });
  $db->firstsync();

  return ['registered', [$accountid, $email]];
}

sub handle_signup {
  my $detail = shift;

  my $force = delete $detail->{force};
  $detail->{imapPort} ||= 993;
  $detail->{imapSSL} ||= 2;
  $detail->{smtpPort} ||= 587;
  $detail->{smtpSSL} ||= 3;

  if ($detail->{username} =~ m/\@icloud\.com/) {
    $detail->{imapHost} = 'imap.mail.me.com';
    $detail->{smtpHost} = 'smtp.mail.me.com';
    $detail->{caldavURL} = 'https://caldav.icloud.com/';
    $detail->{carddavURL} = 'https://contacts.icloud.com/';
    $force = 1;
  }

  elsif ($detail->{username} =~ m/\@yahoo\.com/) {
    $detail->{imapHost} = 'imap.mail.yahoo.com',
    $detail->{smtpHost} = 'smtp.mail.yahoo.com';
    $detail->{caldavURL} = 'https://caldav.calendar.yahoo.com';
    $detail->{carddavURL} = 'https://carddav.address.yahoo.com';
    $force = 1;
  }

  else {
    my $Resolver = Net::DNS::Resolver->new;
    my $domain = $detail->{username};
    $domain =~ s/.*\@//;
    my $reply;
    warn "RESOLVING: $domain\n";
    ($reply) = $Resolver->query("_imaps._tcp.$domain", "srv");
    if ($reply) {
      my @d = $reply->answer;
      if (@d) {
        $detail->{imapHost} = $d[0]->target();
        $detail->{imapPort} = $d[0]->port();
      }
    }
    else {
      my ($reply) = $Resolver->query("_imap._tcp.$domain", "srv");
      if ($reply) {
        my @d = $reply->answer;
        if (@d) {
          $detail->{imapHost} = $d[0]->target();
          $detail->{imapPort} = $d[0]->port();
          $detail->{imapSSL} = 3;
        }
      }
    }

    ($reply) = $Resolver->query("_smtps._tcp.$domain", "srv");
    if ($reply) {
      my @d = $reply->answer;
      if (@d) {
        $detail->{smtpHost} = $d[0]->target();
        $detail->{smtpPort} = $d[0]->port();
        $detail->{smtpSSL} = 2;
      }
    }
    else {
      my ($reply) = $Resolver->query("_submission._tcp.$domain", "srv");
      if ($reply) {
        my @d = $reply->answer;
        if (@d) {
          $detail->{smtpHost} = $d[0]->target();
          $detail->{smtpPort} = $d[0]->port();
          $detail->{smtpSSL} = 3;
        }
      }
    }

    ($reply) = $Resolver->query("_caldavs._tcp.$domain", "srv");
    if ($reply) {
      my @d = $reply->answer;
      if (@d) {
        my $host = $d[0]->target();
        my $port = $d[0]->port();
        $detail->{caldavURL} = "https://$host";
        $detail->{caldavURL} .= ":$port" unless $port eq 443;
      }
    }
    else {
      my ($reply) = $Resolver->query("_caldav._tcp.$domain", "srv");
      if ($reply) {
        my @d = $reply->answer;
        if (@d) {
          my $host = $d[0]->target();
          my $port = $d[0]->port();
          $detail->{caldavURL} = "http://$host";
          $detail->{caldavURL} .= ":$port" unless $port eq 80;
        }
      }
    }

    ($reply) = $Resolver->query("_carddavs._tcp.$domain", "srv");
    if ($reply) {
      my @d = $reply->answer;
      if (@d) {
        my $host = $d[0]->target();
        my $port = $d[0]->port();
        $detail->{carddavURL} = "https://$host";
        $detail->{carddavURL} .= ":$port" unless $port eq 443;
      }
    }
    else {
      my ($reply) = $Resolver->query("_carddav._tcp.$domain", "srv");
      if ($reply) {
        my @d = $reply->answer;
        if (@d) {
          my $host = $d[0]->target();
          my $port = $d[0]->port();
          $detail->{carddavURL} = "http://$host";
          $detail->{carddavURL} .= ":$port" unless $port eq 80;
        }
      }
    }
  }

  unless ($force) {
    return ['signup', ['continue', $detail]];
  }

  my $imap = Mail::IMAPTalk->new(
   Server => $detail->{imapHost},
   Port => $detail->{imapPort},
   UseSSL => ($detail->{imapSSL} > 1),
   UseBlocking => ($detail->{imapSSL} > 1),
  );
  die "UNABLE TO CONNECT for $detail->{username}\n" unless $imap;

  my $ok = $imap->login($detail->{username}, $detail->{password});
  die "LOGIN FAILED FOR $detail->{username}" unless $ok;
  my $capa = $imap->capability();
  $imap->logout();

  my $dbh = accountsdb();
  my ($existing, $type) = $dbh->selectrow_array("SELECT accountid, type FROM accounts WHERE email = ?", {}, $detail->{username});
  if ($existing) {
    set_accountid($existing);
  }
  else {
    $dbh->do("INSERT INTO accounts (email, accountid, type) VALUES (?, ?, ?)", {}, $detail->{username}, $accountid, 'imap');
  }
  getdb();
  $db->setuser($detail);
  $db->firstsync();

  return ['signup', ['done', $accountid, $detail->{username}]];
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
  my ($accountid, $type, $content) = @$req;

  my $api = JMAP::API->new($db);
  my ($res) = $api->uploadFile($accountid, $type, $content);

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

  use Data::Dumper;
  warn Dumper($request, \@res) if $ENV{DEBUGJMAP};

  return ['jmap', \@res];
}
