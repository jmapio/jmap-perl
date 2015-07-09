#!/usr/bin/perl -w

use strict;
use lib '/home/jmap/jmap-perl';
package SyncServer;

#use Mail::IMAPTalk qw(:trace);

use AnyEvent;
use AnyEvent::Handle;
use JSON::XS qw(encode_json decode_json);
use Net::Server::PreFork;
use JMAP::Sync::Gmail;
use JMAP::Sync::ICloud;

use base qw(Net::Server::PreFork);

# we love globals
my $hdl;
my $cv;
my $id;
my $backend;

$0 = '[jmap proxy imapsync]';

sub setup {
  my $config = shift;
  if ($config->{hostname} eq 'gmail') {
    $backend = JMAP::Sync::Gmail->new($config) || die "failed to setup $id";
  } elsif ($config->{hostname} eq 'imap.mail.me.com') {
    $backend = JMAP::Sync::ICloud->new($config) || die "failed to setup $id";
  } else {
    die "UNKNOWN ID $id ($config->{hostname})";
  }
  warn "$$ Connected $id";
  $0 = "[jmap proxy imapsync] $id";
  $hdl->push_write(json => [ 'setup', $id ]);
  $hdl->push_write("\n");
}

sub process_request {
  my $server = shift;
  $cv = AnyEvent->condvar;

  close STDIN;
  close STDOUT;
  $hdl = AnyEvent::Handle->new(
    fh => $server->{server}{client},
    on_error => sub {
      my ($hdl, $fatal, $msg) = @_;
      $hdl->destroy;
      $cv->send;
    },
    on_disconnect => sub {
      my ($hdl, $fatal, $msg) = @_;
      $hdl->destroy;
      $cv->send;
    },
  );

  # first item is always an authentication
  $hdl->push_read(json => sub {
    my $handle = shift;
    my $json = shift;
    $id = $json->{username};
    setup($json);
    $handle->push_read(json => mk_handler());
  });

  $cv->recv;
  $cv->send;
  exit 0;
}

SyncServer->run(host => '127.0.0.1', port => 5005);

sub handle_ping {
  return ['pong', $id];
}

sub handle_status {
  my $args = shift;
  my $data = $backend->fetch_status(@$args);
  return ['status', $data];
}

sub handle_folder {
  my $args = shift;
  my $data = $backend->fetch_folder(@$args);
  return ['folder', $data];
}

sub handle_folders {
  my $args = shift;
  my $data = $backend->folders(@$args);
  return ['folders', $data];
}

sub handle_calendars {
  my $args = shift;
  my $data = $backend->get_calendars(@$args);
  return ['calendars', $data];
}

sub handle_events {
  my $args = shift;
  my $data = $backend->get_events(@$args);
  return ['events', $data];
}

sub handle_abooks {
  my $args = shift;
  my $data = $backend->get_abooks(@$args);
  return ['abooks', $data];
}

sub handle_contacts {
  my $args = shift;
  my $data = $backend->get_contacts(@$args);
  return ['contacts', $data];
}

sub handle_send {
  my $args = shift;
  my $data = $backend->send_email(@$args);
  return ['sent', $data];
}

sub handle_imap_update {
  my $args = shift;
  my $data = $backend->imap_update(@$args);
  return ['updated', $data];
}

sub handle_imap_move {
  my $args = shift;
  my $data = $backend->imap_move(@$args);
  return ['moved', $data];
}

sub handle_imap_fill {
  my $args = shift;
  my $data = $backend->imap_fill(@$args);
  return ['filled', $data];
}

sub handle_imap_fetch {
  my $args = shift;
  my $data = $backend->imap_fetch(@$args);
  return ['fetched', $data];
}

sub handle_imap_count {
  my $args = shift;
  my $data = $backend->imap_count(@$args);
  return ['counted', $data];
}

sub mk_handler {
  my ($db) = @_;

  # don't last forever
  $hdl->{killer} = AnyEvent->timer(after => 600, cb => sub { warn "$$ SHUTTING DOWN $id ON TIMEOUT\n"; undef $hdl; $cv->send });

  return sub {
    my ($hdl, $json) = @_;

    # make sure we have a connection

    my ($cmd, $args, $tag) = @$json;
    my $res = eval {
      my $fn = "handle_$cmd";
      if (SyncServer->can($fn)) {
        no strict 'refs';
        return $fn->($args);
      }
      die "Unknown command $cmd";
    };
    unless ($res) {
      $res = ['error', "$@"]
    }
    $res->[2] = $tag;
    $hdl->push_write(json => $res);
    $hdl->push_write("\n");

    warn "$$ HANDLED $cmd ($tag) => $res->[0] ($id)\n";
    $hdl->push_read(json => mk_handler($db));
  };
}
