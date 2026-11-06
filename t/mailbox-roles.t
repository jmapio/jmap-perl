#!/usr/bin/perl
#
# sync_jmailboxes: which folder gets which mailbox role. A special-use
# attribute always counts; a folder name only for a folder at the top of the
# personal namespace, decoded from modified UTF-7, and only when no other
# folder claims the same role -- else one would be merged onto the other.

use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use lib '.';

$ENV{JMAP_DATADIR} = tempdir(CLEANUP => 1);
require JMAP::ImapDB;

my $n = 0;
sub roles_for {
  my @folders = @_;   # [imapname, label]
  my $db = JMAP::ImapDB->new('roles' . ++$n);
  $db->begin();
  $db->dinsert('ifolders', { sep => '/', imapname => $_->[0], label => $_->[1] }) for @folders;
  $db->commit();
  $db->sync_jmailboxes();
  $db->begin();
  my $boxes = $db->dget('jmailboxes', { active => 1 });
  my $byid = { map { $_->{jmailboxid} => $_ } @$boxes };
  my $folders = $db->dget('ifolders');
  $db->commit();
  my %role = map { $_->{imapname} => $byid->{$_->{jmailboxid}}{role} } @$folders;
  my %box  = map { $_->{imapname} => $_->{jmailboxid} } @$folders;
  return (\%role, \%box, scalar @$boxes);
}

{
  my ($role) = roles_for(['INBOX', 'INBOX'], ['Sent', 'Sent'], ['Trash', 'Trash'], ['Work', 'Work']);
  is_deeply($role, { INBOX => 'inbox', Sent => 'sent', Trash => 'trash', Work => undef },
    'English names give their roles');
}

{
  my ($role) = roles_for(['INBOX', 'INBOX'], ['Projects', 'Projects'], ['Projects/Archive', 'Projects/Archive'],
                         ['Clients', 'Clients'], ['Clients/Sent', 'Clients/Sent']);
  is($role->{'Projects/Archive'}, undef, 'a nested folder claims no role by its name');
  is($role->{'Clients/Sent'}, undef, '... whatever it is called');
}

{
  my ($role, $box, $count) = roles_for(['INBOX', 'INBOX'], ['Sent', 'Sent'], ['Sent Items', 'Sent Items']);
  isnt($box->{Sent}, $box->{'Sent Items'}, 'two folders named for one role keep a mailbox each');
  is($count, 3, '... so none of them vanishes');
  is($role->{Sent}, undef, '... and neither is guessed to be the sent mailbox');
  is($role->{'Sent Items'}, undef, '... nor the other');
}

{
  my ($role, $box, $count) = roles_for(['INBOX', 'INBOX'], ['Sent', '\\Sent'], ['Sent Items', 'Sent Items']);
  is($role->{Sent}, 'sent', 'a special-use attribute still gives its role');
  isnt($box->{Sent}, $box->{'Sent Items'}, '... and a folder only named like it is not merged onto it');
  is($count, 3, '... so it stays visible');
}

done_testing;
