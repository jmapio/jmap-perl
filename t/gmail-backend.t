#!/usr/bin/perl
#
# The Gmail backend as the sync sees it: folder labels have to be the names
# messages carry in X-GM-LABELS, whichever listing Gmail answers.

use strict;
use warnings;
use Test::More;
use lib '.';
use JMAP::Sync::Gmail;

{
  package FakeIMAP;
  sub new        { my ($class, %args) = @_; bless {%args}, $class }
  sub namespace  { [[['', '/']]] }
  sub capability { $_[0]{caps} }
  sub xlist      { $_[0]{broken_xlist} ? ('ok') : @{$_[0]{rows}} }
  sub list       { @{$_[0]{rows}} }
  sub logout     {}
}

sub labels_for {
  my ($caps, @rows) = @_;
  my $broken = delete $caps->{broken_xlist};
  my $self = bless { auth => {}, imap => FakeIMAP->new(caps => $caps, rows => \@rows,
                                                        broken_xlist => $broken) },
    'JMAP::Sync::Gmail';
  my (undef, $folders) = @{ $self->folders() };
  return { map { $_ => $folders->{$_}[1] } keys %$folders };
}

my %expected = (
  'INBOX'             => '\\Inbox',
  '[Gmail]/All Mail'  => '\\AllMail',
  '[Gmail]/Starred'   => '\\Starred',
  '[Gmail]/Important' => '\\Important',
  '[Gmail]/Spam'      => '\\Spam',
  '[Gmail]/Trash'     => '\\Trash',
  'Work'              => 'Work',
);

# --- XLIST, which Gmail advertises and the backend prefers ---------------------

is_deeply(labels_for({ xlist => 1 },
  [['\\HasNoChildren', '\\Inbox'],     '/', 'INBOX'],
  [['\\HasNoChildren', '\\AllMail'],   '/', '[Gmail]/All Mail'],
  [['\\HasNoChildren', '\\Starred'],   '/', '[Gmail]/Starred'],
  [['\\HasNoChildren', '\\Important'], '/', '[Gmail]/Important'],
  [['\\HasNoChildren', '\\Spam'],      '/', '[Gmail]/Spam'],
  [['\\HasNoChildren', '\\Trash'],     '/', '[Gmail]/Trash'],
  [['\\HasNoChildren'],                '/', 'Work'],
), \%expected, 'XLIST: the system folders keep their XLIST names');

# --- RFC 6154 LIST, should Gmail stop advertising XLIST ------------------------

is_deeply(labels_for({},
  [['\\HasNoChildren'],                '/', 'INBOX'],
  [['\\All', '\\HasNoChildren'],       '/', '[Gmail]/All Mail'],
  [['\\Flagged', '\\HasNoChildren'],   '/', '[Gmail]/Starred'],
  [['\\HasNoChildren', '\\Important'], '/', '[Gmail]/Important'],
  [['\\HasNoChildren', '\\Junk'],      '/', '[Gmail]/Spam'],
  [['\\HasNoChildren', '\\Trash'],     '/', '[Gmail]/Trash'],
  [['\\HasNoChildren'],                '/', 'Work'],
), \%expected, 'LIST: \\All, \\Flagged, \\Junk and a bare INBOX get the same names');

# --- XLIST advertised but unusable, so folders() falls back to LIST ------------

is_deeply(labels_for({ xlist => 1, broken_xlist => 1 },
  [['\\HasNoChildren'],                '/', 'INBOX'],
  [['\\All', '\\HasNoChildren'],       '/', '[Gmail]/All Mail'],
  [['\\Flagged', '\\HasNoChildren'],   '/', '[Gmail]/Starred'],
  [['\\HasNoChildren', '\\Important'], '/', '[Gmail]/Important'],
  [['\\HasNoChildren', '\\Junk'],      '/', '[Gmail]/Spam'],
  [['\\HasNoChildren', '\\Trash'],     '/', '[Gmail]/Trash'],
  [['\\HasNoChildren'],                '/', 'Work'],
), \%expected, 'LIST fallback after a broken XLIST: the same names again');

done_testing;
