#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use lib '.';
use JMAP::Sync::Common;

# folder_label() takes a LIST/XLIST row, [\@flags, $separator, $name], all of
# it straight off the wire. RFC 3501 permits a NIL hierarchy delimiter, and
# interpolating that undef into a character class -- as this once did -- gives
# m/^[]/, a fatal "Unmatched [ in regex" on every sync.

my $label = \&JMAP::Sync::Common::folder_label;

# --- the ordinary cases ----------------------------------------------------

is($label->('INBOX.', [['\\HasNoChildren'], '.', 'INBOX.Archive']), 'Archive',
   'strips the namespace prefix');

is($label->('', [['\\HasNoChildren'], '/', 'Archive']), 'Archive',
   'empty prefix leaves the name alone');

is($label->('INBOX.', [['\\HasNoChildren'], '.', 'INBOX.Work.Projects']), 'Work.Projects',
   'only the leading prefix is stripped, not later separators');

# A special-use flag wins over the derived name. \HasNoChildren and friends are
# structural, not roles, so they must not be mistaken for one.
is($label->('INBOX.', [['\\HasNoChildren', '\\Sent'], '.', 'INBOX.Sent']), '\\Sent',
   'a role flag is used as the label when present');

is($label->('INBOX.', [['\\HasChildren', '\\NoSelect'], '.', 'INBOX.Stuff']), 'Stuff',
   'structural flags alone are not treated as a role');

# --- the crash: NIL separator ----------------------------------------------

{
  my $got = eval { $label->('INBOX.', [['\\Noselect'], undef, 'INBOX.Weird']) };
  ok(!$@, 'a NIL (undef) separator does not die')
    or diag "died: $@";
  is($got, 'Weird', 'prefix still stripped with a NIL separator');
}

{
  my $got = eval { $label->('', [['\\Noselect'], undef, 'INBOX']) };
  ok(!$@, 'NIL separator with an empty prefix does not die')
    or diag "died: $@";
  is($got, 'INBOX', 'name returned unchanged');
}

# --- undef / missing name --------------------------------------------------

{
  my $got = eval { $label->('INBOX.', [['\\Noselect'], '.', undef]) };
  ok(!$@, 'an undef folder name does not die')
    or diag "died: $@";
  is($got, '', 'undef name yields an empty label, not undef');
}

# --- undef prefix (server returned a NIL personal namespace) ---------------

{
  my $got = eval { $label->(undef, [['\\HasNoChildren'], '/', 'Archive']) };
  ok(!$@, 'an undef prefix does not die')
    or diag "died: $@";
  is($got, 'Archive', 'undef prefix behaves like an empty one');
}

# --- prefix and separator must be literal, not regex ------------------------
# "INBOX." is the common Cyrus prefix and "." matches any character, so a
# regex-interpolated prefix would eat a character it should not.

is($label->('INBOX.', [['\\HasNoChildren'], '.', 'INBOXXArchive']), 'INBOXXArchive',
   'prefix is matched literally, so INBOXX is not mistaken for INBOX.');

is($label->('a+b', [['\\HasNoChildren'], '/', 'a+b/Mail']), 'Mail',
   'regex metacharacters in the prefix are quoted');

is($label->('', [['\\HasNoChildren'], '|', '|Mail']), 'Mail',
   'a separator that is a regex metacharacter is quoted');

is($label->('', [['\\HasNoChildren'], '\\', '\\Mail']), 'Mail',
   'a backslash separator does not corrupt the pattern');

# --- separator stripped only when it actually leads ------------------------

is($label->('INBOX.', [['\\HasNoChildren'], '/', 'INBOX.Archive']), 'Archive',
   'a separator that does not lead the remainder is left alone');

done_testing();
