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
  is($role->{Sent}, 'sent', '... and the one named exactly for the role gets it');
  is($role->{'Sent Items'}, undef, '... and the other none');
}

{
  my ($role, $box, $count) = roles_for(['INBOX', 'INBOX'], ['Sent', '\\Sent'], ['Sent Items', 'Sent Items']);
  is($role->{Sent}, 'sent', 'a special-use attribute still gives its role');
  isnt($box->{Sent}, $box->{'Sent Items'}, '... and a folder only named like it is not merged onto it');
  is($count, 3, '... so it stays visible');
}

{
  # 'Entwürfe' and 'Gelöschte Objekte' as a server lists them
  my ($role) = roles_for(['Entw&APw-rfe', 'Entw&APw-rfe'], ['Gesendet', 'Gesendet'],
                         ['Gel&APY-schte Objekte', 'Gel&APY-schte Objekte'], ['Papierkorb-alt', 'Papierkorb-alt']);
  is($role->{'Entw&APw-rfe'}, 'drafts', 'a modified UTF-7 name is decoded before the lookup');
  is($role->{'Gesendet'}, 'sent', 'German names give their roles');
  is($role->{'Gel&APY-schte Objekte'}, 'trash', '... non-ASCII ones too');
  is($role->{'Papierkorb-alt'}, undef, 'a name that only starts like one gives nothing');
}

{
  my ($role, $box, $count) = roles_for(['INBOX', 'INBOX'], ['Sent', 'Sent'], ['Gesendet', 'Gesendet']);
  isnt($box->{Sent}, $box->{Gesendet}, '"Sent" and "Gesendet" keep a mailbox each');
  is($count, 3, '... so neither vanishes');
  is($role->{Sent}, 'sent', 'English "Sent" wins over "Gesendet"');
  is($role->{Gesendet}, undef, '... which stays a plain mailbox');
}

{
  my ($role) = roles_for(['INBOX', 'INBOX'], ['Posteingang', 'Posteingang'], ['Werbung', 'Werbung']);
  is($role->{INBOX}, 'inbox', 'a folder called "Posteingang" does not take the inbox role from INBOX');
  is($role->{Posteingang}, undef, '... nor get it');
  is($role->{Werbung}, undef, '"Werbung" is a folder people read, not junk');
}

done_testing;
