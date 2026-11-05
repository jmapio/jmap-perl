package JMAP::EventId;

# CalendarEvent ids.  draft-ietf-jmap-calendars S5 makes "id" server-set and
# RFC 8620 S1.2 limits every Id to 1-255 characters of the base64url alphabet
# (A-Z a-z 0-9 - _), but events are keyed by their iCalendar UID, which can be
# any string: "abc@example.com", an Outlook hex blob, a URL.  Handing the UID
# out as the id breaks clients that hold ids to the rules (Bulwark's device
# sync rejects every event of such an account).  Pure: no I/O, no DB.
# t/eventid.t covers it.
#
#   event     the UID itself, when it matches $PLAIN, so most ids never change;
#             else "_h" . base64url(sha256(UID))                (45 characters)
#   instance  "_r" . YYYYMMDD[THHMMSS] . "_" . the event's id   (at most 218)
#             one occurrence of a recurring event (S5.11 synthetic id)
#
# Every id minted here starts with "_", and a UID starting with "_" is hashed,
# so a UID can never pass for a minted id.  A hashed id cannot be turned back
# into its UID without the list of UIDs; the caller looks it up.

use strict;
use warnings;
use Digest::SHA qw(sha256);
use MIME::Base64 qw(encode_base64url);

# At most 200 characters, which leaves room for an instance's prefix.
my $PLAIN  = qr/\A[A-Za-z0-9-][A-Za-z0-9_-]{0,199}\z/;
my $HASHED = qr/\A_h[A-Za-z0-9_-]{43}\z/;

# A UID can arrive as characters (from a client's JSON) or as the UTF-8
# octets the database returns; both must give the same id.
sub _octets {
  my ($s) = @_;
  utf8::encode($s) if utf8::is_utf8($s);
  return $s;
}

# The hashed form of the id of the event whose UID is $uid. Every event has
# one, plain UID or not: the database keeps it (jevents.jeventhash) so a
# hashed id is found by lookup, and an instance id too long otherwise uses it.
sub hash_id {
  my ($uid) = @_;
  return '_h' . encode_base64url(sha256(_octets($uid)));
}

# The id of the event whose UID is $uid.
sub master_id {
  my ($uid) = @_;
  return $uid if $uid =~ $PLAIN;
  return hash_id($uid);
}

# Whether $id has the shape of a hashed event id.
sub is_hashed {
  my ($id) = @_;
  return defined $id && $id =~ $HASHED ? 1 : 0;
}

# The id of the instance at recurrence id $rid (a LocalDateTime, or a date
# for an all-day series) of the event whose UID is $uid.
sub instance_id {
  my ($uid, $rid) = @_;
  my $token = $rid =~ /\A(\d{4})-(\d\d)-(\d\d)(?:T(\d\d):(\d\d):(\d\d))?\z/
    ? "$1$2$3" . (defined $4 ? "T$4$5$6" : '')
    : 'X' . unpack('H*', _octets($rid));
  my $id = "_r${token}_" . master_id($uid);
  # RFC 8620 S1.2: at most 255 octets. A long plain UID with a recurrence id
  # that is not a date can pass that; its hashed form is shorter. A
  # recurrence id too long for even that gives no id: the instance is not
  # offered.
  $id = "_r${token}_" . hash_id($uid) if length $id > 255;
  return length $id > 255 ? undef : $id;
}

# The id of an event ($rid undef) or of one of its instances.
sub event_id {
  my ($uid, $rid) = @_;
  return defined $rid ? instance_id($uid, $rid) : master_id($uid);
}

# An id taken apart: ($event_id) for an event, ($event_id, $rid) for one
# instance, () for nothing.  It does not say whether such an event exists:
# the caller turns $event_id into a UID (a lookup when is_hashed) and should
# check that event_id() of the result gives the same id back.
sub parse_id {
  my ($id) = @_;
  return () unless defined $id && length $id;
  if ($id =~ /\A_r(\d{4})(\d\d)(\d\d)(?:T(\d\d)(\d\d)(\d\d))?_(.+)\z/s) {
    return ($7, defined $4 ? "$1-$2-$3T$4:$5:$6" : "$1-$2-$3");
  }
  if ($id =~ /\A_rX((?:[0-9a-f]{2})+)_(.+)\z/s) {
    my ($hex, $event) = ($1, $2);
    my $rid = pack('H*', $hex);
    utf8::decode($rid);
    return ($event, $rid);
  }
  return ($id);
}

1;
