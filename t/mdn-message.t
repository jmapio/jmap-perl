#!/usr/bin/perl
# MDN/send writes client values (subject, reportingUA, finalRecipient, the
# disposition) into header fields: a line break in one must be refused, not
# written, and the message is built by Email::MIME so non-ASCII is encoded.
use strict;
use warnings;
use utf8;
use Test::More;
use lib '.';
use Email::MIME;
package JMAP::API { require './JMAP/API/MDN.pm' }

my $ok = { forEmailId => 'm1', disposition => { actionMode => 'manual-action',
  sendingMode => 'mdn-sent-manually', type => 'displayed' } };
is_deeply([JMAP::API::_mdn_invalid_properties($ok)], [], 'a good MDN passes');
is_deeply([JMAP::API::_mdn_invalid_properties({ %$ok, subject => "Hi\r\nBcc: victim\@example.com" })],
  ['subject'], 'a subject with a line break is refused');
is_deeply([JMAP::API::_mdn_invalid_properties({ %$ok, reportingUA => "ua\nX: y",
  finalRecipient => "rfc822; a\@b\r\n" })], ['reportingUA', 'finalRecipient'], 'so are reportingUA and finalRecipient');
is_deeply([JMAP::API::_mdn_invalid_properties({ %$ok, disposition => { %{$ok->{disposition}}, type => "displayed\r\nX: y" } })],
  ['disposition/type'], 'a disposition value outside RFC 9007\'s set is refused');
is_deeply([JMAP::API::_mdn_invalid_properties({ %$ok, disposition => { %{$ok->{disposition}}, actionMode => 'Manual-Action' } })],
  ['disposition/actionMode'], 'they are case-sensitive (RFC 9007 S2)');

my $raw = JMAP::API::_mdn_message(from_name => 'Jöe', from_email => 'joe@example.com',
  to => 'sender@example.com', subject => 'Read: héllo', date => 'Mon, 2 Nov 2026 10:00:00 +0000',
  message_id => '<mdn.1@example.com>', text => "Read.\r\n",
  fields => ['Reporting-UA' => 'ua', 'Final-Recipient' => 'rfc822; joe@example.com',
             'Disposition' => 'manual-action/mdn-sent-manually;displayed']);
unlike($raw, qr/[^\x00-\x7f]/, 'the message is ASCII');
my $m = Email::MIME->new($raw);
is($m->header_str('Subject'), 'Read: héllo', 'the subject is RFC 2047 encoded and decodes back');
like($m->header_str('From'), qr/Jöe.*<joe\@example\.com>/, 'and the From name');
like($m->content_type, qr{^multipart/report;.*report-type="?disposition-notification}s, 'multipart/report');
my @p = $m->subparts;
is(scalar @p, 2, 'two parts');
is($p[0]->body_str, "Read.\r\n", 'the text');
like($p[1]->body, qr/^Disposition: manual-action\/mdn-sent-manually;displayed\r?$/m, 'the report fields');
ok(!defined $p[0]->header('Date'), 'no Date on a part');

done_testing;
