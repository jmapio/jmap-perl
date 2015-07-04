#!/usr/bin/perl -c

use strict;
use warnings;

package JMAP::Sync::Common;

use Mail::IMAPTalk;
use JSON::XS qw(encode_json decode_json);
use Email::Simple;
use Email::Sender::Simple qw(sendmail);
use Email::Sender::Transport::SMTPS;
use Net::CalDAVTalk;
use Net::CardDAVTalk;

my %KNOWN_SPECIALS = map { lc $_ => 1 } qw(\\HasChildren \\HasNoChildren \\NoSelect \\NoInferiors);

sub new {
  my $Class = shift;
  my $auth = shift;
  return bless { auth => $auth }, ref($Class) || $Class;
}

sub DESTROY {
  my $Self = shift;
  if ($Self->{imap}) {
    $Self->{imap}->logout();
  }
}

sub get_calendars {
  my $Self = shift;
  my $talk = $Self->connect_calendars();

  my $data = $talk->GetCalendars();

  return $data;
}

sub get_events {
  my $Self = shift;
  my $Args = shift;
  my $talk = $Self->connect_calendars();

  my $data = $talk->GetEvents($Args->{href}, Full => 1);

  my %res;
  foreach my $item (@$data) {
    $res{$item->{id}} = $item->{_raw};
  }

  return \%res;
}

sub get_abooks {
  my $Self = shift;
  my $talk = $Self->connect_contacts();

  my $data = $talk->GetAddressBooks();

  return $data;
}

sub get_contacts {
  my $Self = shift;
  my $Args = shift;
  my $talk = $Self->connect_contacts();

  my $data = $talk->GetContacts($Args->{path});

  my %res;
  foreach my $item (@$data) {
    $res{$item->{CPath}} = $item->{_raw};
  }

  return \%res;
}

# read folder list from the server
sub folders {
  my $Self = shift;
  $Self->connect_imap();
  return $Self->{folders};
}

sub labels {
  my $Self = shift;
  $Self->connect_imap();
  return $Self->{labels};
}

sub fetch_status {
  my $Self = shift;
  my $justfolders = shift;

  my $imap = $Self->connect_imap();

  my $folders = $Self->folders;
  if ($justfolders) {
    my %data = map { $_ => $folders->{$_} }
               grep { exists $folders->{$_} }
               @$justfolders;
    $folders = \%data;
  }

  my $fields = "(uidvalidity uidnext highestmodseq messages)";
  my $data = $imap->multistatus($fields, sort keys %$folders);

  return $data;
}

sub fetch_bodies {
  my $Self = shift;
  my $request = shift;

  my $imap = $Self->connect_imap();

  my %res;
  foreach my $item (@$request) {
    my $name = $item->[0];
    my $uids = $item->[1];

    my $r = $imap->examine($name);
    die "EXAMINE FAILED $r" unless (lc($r) eq 'ok' or lc($r) eq 'read-only');

    my $messages = $imap->fetch(join(',', @$uids), "rfc822");

    foreach my $uid (keys %$messages) {
      $res{$name}{$uid} = $messages->{$uid}{rfc822};
    }
  }

  return \%res;
}

1;
