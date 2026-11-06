#!/usr/bin/perl
#
# DAV clients are kept for the life of the worker, an OAuth access token for
# an hour: a kept client must always carry the current token.

use strict;
use warnings;
use Test::More;
use lib '.';
use JMAP::Sync::Gmail;
use JMAP::Sync::Fastmail;
use JMAP::Sync::AOL;
use JMAP::Sync::Standard;

{
  package FakeOAuth;
  my $issued = 0;
  sub refresh { $issued++; return { access_token => "fresh$issued", expires_in => 3600 } }
}

no warnings 'redefine', 'once';
local *JMAP::Sync::Gmail::O             = sub { bless {}, 'FakeOAuth' };
local *JMAP::Sync::AOL::O               = sub { bless {}, 'FakeOAuth' };
local *JMAP::Sync::Fastmail::_get_oauth = sub { bless {}, 'FakeOAuth' };

for my $class (qw(JMAP::Sync::Gmail JMAP::Sync::Fastmail JMAP::Sync::AOL)) {
  my $self = bless { auth => { password   => 'refresh-token',
                               caldavURL  => 'https://cal.test/',
                               carddavURL => 'https://card.test/' } }, $class;
  my $cal  = $self->{calendars} = bless { access_token => 'stale' }, 'FakeDAV';
  my $card = $self->{contacts}  = bless { access_token => 'stale' }, 'FakeDAV';

  is($self->connect_calendars, $cal, "$class: the calendar client is kept");
  my $first = $cal->{access_token};
  like($first, qr/^fresh\d+$/, "$class: but carries the current token");
  is($self->connect_contacts, $card, "$class: the address book client is kept");
  is($card->{access_token}, $first, "$class: and carries the same token");

  $self->{access_token_expires} = time() - 1;
  $self->connect_calendars;
  isnt($cal->{access_token}, $first, "$class: an expired token is replaced in the kept client");
  like($cal->{access_token}, qr/^fresh\d+$/, "$class: by a freshly issued one");

  is($self->connect_files, undef, "$class: no WebDAV URL is no client, and no error");
}

# A password account: the kept client keeps its password
{
  my $self = bless { auth => { username => 'u', password => 'secret',
                               caldavURL => 'https://cal.test/' } }, 'JMAP::Sync::Standard';
  my $cal = $self->{calendars} = bless { password => 'secret' }, 'FakeDAV';
  is($self->connect_calendars, $cal, 'password account: the client is kept');
  is($cal->{password}, 'secret', 'password account: and keeps its password');
  ok(!exists $cal->{access_token}, 'password account: and gets no token');
}

done_testing;
