#!/usr/bin/perl
# JMAP::PDPA: export an account to a zip and import that zip into another,
# against fakes of the worker's commands.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use lib '.';
use JMAP::PDPA;

my $tmp = tempdir(CLEANUP => 1);
my $t = \1;

# the source account
my %src = (
  mailboxes => [ { id => 'mb1', name => 'INBOX' }, { id => 'mb2', name => 'Sub', parentId => 'mb1' },
                 { id => 'mb3', name => '..', parentId => 'mb1' } ],
  emails => { e1 => { mailboxIds => { mb1 => $t }, keywords => { '$seen' => $t }, receivedAt => '2026-01-01T00:00:00Z' },
              e2 => { mailboxIds => { mb2 => $t }, keywords => {} },
              e3 => { mailboxIds => { mb3 => $t }, keywords => {} } },
  books => [ { id => 'ab1', name => 'Personal' } ],
  cards => { ab1 => [ { id => 'c1', uid => 'urn:uuid:c1', name => { full => 'Ann' }, addressBookIds => { ab1 => $t } } ] },
  cals  => [ { id => 'cal1', name => 'Work' } ],
  events => { cal1 => [ { id => 'v1', uid => 'v1@x', title => 'Meet', calendarIds => { cal1 => $t } } ] },
);
my $export_call = sub {
  my ($cmd, $a) = @_;
  if ($cmd eq 'fetch_blobs') {
    my %r;
    for my $id (@{ $a->{ids} }) {
      my $p = "$tmp/$id"; open(my $fh, '>', $p) or die; print $fh "Subject: $id\r\n\r\nbody\r\n"; close $fh;
      $r{$id} = { path => $p, is_temp => 1 };
    }
    return \%r;
  }
  die "unexpected $cmd" unless $cmd eq 'jmap';
  my @out;
  for my $c (@{ $a->{methodCalls} }) {
    my ($m, $args, $tag) = @$c;
    my $r;
    if    ($m eq 'Mailbox/get')    { $r = { list => $src{mailboxes} } }
    elsif ($m eq 'Email/query')    { $r = { ids => ($args->{position} ? [] : [ sort keys %{ $src{emails} } ]) } }
    elsif ($m eq 'Email/get')      { $r = { list => [ map { { id => $_, %{ $src{emails}{$_} } } } @{ $args->{ids} } ] } }
    elsif ($m eq 'AddressBook/get'){ $r = { list => $src{books} } }
    elsif ($m eq 'Calendar/get')   { $r = { list => $src{cals} } }
    elsif ($m =~ m{/query$})       { $r = { ids => [] } }
    elsif ($m eq 'ContactCard/get')   { $r = { list => $src{cards}{ab1} } }
    elsif ($m eq 'CalendarEvent/get') { $r = { list => $src{events}{cal1} } }
    push @out, [$m, $r, $tag];
  }
  return { methodResponses => \@out };
};

my $zip = JMAP::PDPA::export(call => $export_call, accountid => 'a1', uuid => 'u', now => 0);
my %files = JMAP::PDPA::unzip($zip);
ok($files{'archive.json'}, 'archive.json');
is($files{'mail/INBOX/1.eml'}, "Subject: m-e1\r\n\r\nbody\r\n", 'a message, in its folder');
ok($files{'mail/INBOX/Sub/folder.json'}, 'a subfolder');
ok(!grep({ m{\.\./|/\.\.(/|\z)} } keys %files), 'no ".." in a path, whatever a mailbox is called');
ok($files{'contacts/Personal/folder.json'} && $files{'calendars/Work/folder.json'}, 'contacts and calendars');
ok(!-e "$tmp/m-e1", 'the fetched temp files are gone');

# import into an empty account
my (%made, @imported, @cards, @events, @moved);
my $n = 0;
my $import_call = sub {
  my ($cmd, $a) = @_;
  return { blobId => 'b' . ++$n } if $cmd eq 'store_blob';
  my @out;
  for my $c (@{ $a->{methodCalls} }) {
    my ($m, $args, $tag) = @$c;
    my $r = {};
    if    ($m eq 'Mailbox/get') { $r = { list => [] } }
    elsif ($m eq 'Mailbox/set') { my $id = 'new' . ++$n; $made{$id} = $args->{create}{m}; $r = { created => { m => { id => $id } } } }
    elsif ($m eq 'Email/import'){ push @imported, $args->{emails}{e};
                                  # the third is already in the account
                                  $r = @imported == 3 ? { notCreated => { e => { type => 'alreadyExists', existingId => 'old3' } } }
                                                      : { created => { e => { id => 'x' } } } }
    elsif ($m eq 'Email/set')   { push @moved, $args->{update}; $r = { updated => { old3 => undef } } }
    elsif ($m =~ m{^(AddressBook|Calendar)/set$}) { $r = { created => { c => { id => "$1-new" } } } }
    elsif ($m eq 'ContactCard/set')   { push @cards, values %{ $args->{create} }; $r = { created => { map { $_ => {} } keys %{ $args->{create} } } } }
    elsif ($m eq 'CalendarEvent/set') { push @events, values %{ $args->{create} }; $r = { created => { map { $_ => {} } keys %{ $args->{create} } } } }
    push @out, [$m, $r, $tag];
  }
  return { methodResponses => \@out };
};
my $count = JMAP::PDPA::import_archive(call => $import_call, zip => $zip, prefix => 'Old', tmpdir => $tmp);
is_deeply($count, { emails => 3, contacts => 1, events => 1 }, 'everything came in');
is_deeply([ map { keys %{ $_->{old3} } } @moved ], [ grep { m{^mailboxIds/} } map { keys %{ $_->{old3} } } @moved ], 'one already there is added to the folder');
is(scalar @moved, 1, 'by one Email/set');
is_deeply([ sort map { $_->{name} } values %made ], [ sort qw(Old INBOX Sub) ], 'the folders, under the prefix (".." goes into its parent)');
my ($seen) = grep { $_->{receivedAt} } @imported;
is_deeply($seen->{keywords}, { '$seen' => JSON::XS::true }, 'flags come back as keywords');
is_deeply($cards[0]{addressBookIds}, { 'AddressBook-new' => JSON::XS::true }, 'a card goes into the new address book');
ok(!exists $cards[0]{id}, 'without its old id');
is_deeply($events[0]{calendarIds}, { 'Calendar-new' => JSON::XS::true }, 'an event into the new calendar');

ok(!eval { JMAP::PDPA::import_archive(call => $import_call, zip => 'not a zip', tmpdir => $tmp); 1 }, 'a bad zip dies');

done_testing;
