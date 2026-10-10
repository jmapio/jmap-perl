#!/usr/bin/perl
# t/query-negative-position.t -- RFC 8620 S5.5: a negative position counts
# back from the end of the results, for every /query (live proxy).
use strict;
use warnings;
use Test::More;
use JSON;
use HTTP::Tiny;
use MIME::Base64;

plan skip_all => 'set JMAP_PROXY_URL' unless $ENV{JMAP_PROXY_URL};
my $user = $ENV{CYRUS_USER} || 'user1';
my $http = HTTP::Tiny->new;
my $auth = 'Basic ' . MIME::Base64::encode_base64("$user:password", '');

sub call {
  my ($using, $method, $args) = @_;
  my $res = $http->post("$ENV{JMAP_PROXY_URL}/jmap/", {
    headers => { Authorization => $auth, 'Content-Type' => 'application/json' },
    content => encode_json({ using => ['urn:ietf:params:jmap:core', $using],
                             methodCalls => [ [ $method, { accountId => $user, %$args }, 'c0' ] ] }),
  });
  die "HTTP $res->{status}" unless $res->{success};
  return decode_json($res->{content})->{methodResponses}[0][1];
}

for my $t (['urn:ietf:params:jmap:principals', 'Principal/query'],
           ['urn:ietf:params:jmap:contacts', 'ContactCard/query'],
           ['urn:ietf:params:jmap:calendars', 'CalendarEvent/query']) {
  my ($cap, $m) = @$t;
  my $all = call($cap, $m, {});
  next if ($all->{type} // '') eq 'unknownMethod';
  my $neg = call($cap, $m, { position => -1 });
  ok(!$neg->{type}, "$m accepts a negative position") or diag explain $neg;
  my @ids = @{ $all->{ids} || [] };
  is_deeply($neg->{ids}, [ @ids ? $ids[-1] : () ], "$m: position -1 is the last id") or diag explain $neg;
}
done_testing;
