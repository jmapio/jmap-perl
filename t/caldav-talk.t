#!/usr/bin/perl

use strict;
use warnings;
use Test::More;

use lib '.';

use JMAP::Sync::CalDAVTalk;

my $NS_D = 'DAV:';
my $NS_C = 'urn:ietf:params:xml:ns:caldav';
my $HOME = '/SOGo/dav/user@example.com/Calendar';

sub calendar {
  my ($href, $name) = @_;
  return {
    "{$NS_D}href" => { content => $href },
    "{$NS_D}propstat" => [{
      "{$NS_D}prop" => {
        "{$NS_D}resourcetype" => { "{$NS_D}collection" => {}, "{$NS_C}calendar" => {} },
        "{$NS_D}displayname" => { content => $name },
        "{http://apple.com/ns/ical/}calendar-color" => { content => '#AABBCCFF' },
      },
    }],
  };
}

sub export_object {
  my ($href) = @_;
  return {
    "{$NS_D}href" => { content => $href },
    "{$NS_D}propstat" => [{ "{$NS_D}prop" => { "{$NS_D}displayname" => { content => $href } } }],
  };
}

# SOGo's answer to a PROPFIND on the calendar home
my @sent;
{
  no warnings 'redefine';
  *Net::DAVTalk::SafeRequest = sub {
    my ($Self, $Method, $Path, $Content) = @_;
    push @sent, "$Content";
    return { error => "501 Request Failed\n" } if "$Content" =~ /D:acl/;
    return { payload => { "{$NS_D}response" => [
      calendar("$HOME/personal/", 'Personal'),
      export_object("$HOME/personal.ics"),
      export_object("$HOME/personal.xml"),
      calendar("$HOME/work/", 'Work'),
    ] } };
  };
}

my $talk = JMAP::Sync::CalDAVTalk->new(url => "https://dav.example.com$HOME/");
isa_ok($talk, 'Net::CalDAVTalk');

my $calendars = eval { $talk->GetCalendars(Sync => 1) };
is($@, '', 'GetCalendars survives a server that fails on DAV:acl');
is_deeply([map { $_->{id} } @{$calendars || []}], ['personal', 'work'], 'every calendar, no export objects');

is(scalar @sent, 1, 'one PROPFIND');
unlike($sent[0], qr/acl/, 'DAV:acl is not requested');
like($sent[0], qr/<D:$_\s*\/>/, "DAV:$_ is still requested") for qw(displayname resourcetype sync-token current-user-privilege-set);

done_testing();
