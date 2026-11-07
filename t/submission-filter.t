#!/usr/bin/perl
# EmailSubmission/query: a FilterOperator is honoured (it matched everything)
use strict;
use warnings;
use Test::More;
use lib '.';
require JMAP::API;

my $api = bless {}, 'JMAP::API';
# rows: [id, threadId, emailId, sendAt, identityId, undoStatus]
my @rows = ([1, 't1', 'e1', 100, 'id1', 'final'], [2, 't2', 'e2', 200, 'id1', 'pending'], [3, 't3', 'e3', 300, 'id1', 'canceled']);
my $ids = sub { [ map { $_->[0] } @{ $api->_submission_filter(\@rows, $_[0]) } ] };
is_deeply($ids->({ undoStatus => 'pending' }), [2], 'a condition');
is_deeply($ids->({ operator => 'NOT', conditions => [{ undoStatus => 'pending' }] }), [1, 3], 'NOT');
is_deeply($ids->({ operator => 'OR', conditions => [{ emailIds => ['e1'] }, { threadIds => ['t3'] }] }), [1, 3], 'OR');
is_deeply($ids->({ operator => 'AND', conditions => [{ emailIds => ['e1', 'e2'] }, { undoStatus => 'final' }] }), [1], 'AND');
is_deeply($ids->({ operator => 'AND', conditions => [{ operator => 'NOT', conditions => [{ emailIds => ['e1'] }] },
  { operator => 'OR', conditions => [{ undoStatus => 'canceled' }, { undoStatus => 'final' }] }] }), [3], 'nested');

done_testing;
