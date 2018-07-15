#!/usr/bin/perl -w

use lib '.';
use Test::More;
use JMAP::EmailObject;
use Path::Tiny;

ok(1, "loads");
is(JMAP::EmailObject::asDate('Sun Jul 15 23:54:16 AEST 2018'), '2018-07-15T13:54:16', 'asDate');
is_deeply(JMAP::EmailObject::asURLs('<https://www.ietf.org/mailman/options/102attendees>, <mailto:102attendees-request@ietf.org?subject=unsubscribe>'), ['https://www.ietf.org/mailman/options/102attendees', 'mailto:102attendees-request@ietf.org?subject=unsubscribe'], 'asURls');
is_deeply(JMAP::EmailObject::asAddresses('"  James Smythe" <james@example.com>, Friends: jane@example.com, =?UTF-8?Q?John_Sm=C3=AEth?= <john@example.com>;'), [
  {name => "James Smythe", email => 'james@example.com'},
  {name => "Friends", email => undef},
  {name => undef, email => 'jane@example.com'},
  {name => "John Smîth", email => 'john@example.com'},
  {name => undef, email => undef},
  ], 'asAddresses');

my $file = "t/resource/structured.eml";
my $obj = JMAP::EmailObject::parse(path($file)->slurp);
use Data::Dumper;
die Dumper($obj);
is_deeply($obj, {}, "parse");
done_testing();

