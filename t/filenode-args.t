#!/usr/bin/perl
# t/filenode-args.t -- the argument schemas for FileNode/get, /changes and
# /set (JMAP::API %PARAM_SCHEMA): a badly typed argument is invalidArguments
# naming it (RFC 8620 S3.6.2), never a serverFail from the handler.
use strict;
use warnings;
use Test::More;
use JSON;
use lib '.';
require JMAP::API;

sub bad { my ($m, $args) = @_; my @b = JMAP::API::_validate_args($m, $args); return [ sort @b ] }

# FileNode/get
is_deeply(bad('FileNode/get', { ids => undef }), [], 'ids null: every node');
is_deeply(bad('FileNode/get', { ids => ['L1', 'L2'], properties => ['name'], fetchParents => JSON::true }), [], 'a well-typed get');
is_deeply(bad('FileNode/get', { ids => 'L1' }), ['ids'], 'ids must be an array');
is_deeply(bad('FileNode/get', { ids => [ { id => 'L1' } ] }), ['ids'], 'of strings');
is_deeply(bad('FileNode/get', { ids => [], properties => 'name' }), ['properties'], 'properties must be an array');
is_deeply(bad('FileNode/get', { ids => [], fetchParents => 'yes' }), ['fetchParents'], 'fetchParents must be a boolean');

# FileNode/changes
is_deeply(bad('FileNode/changes', { sinceState => '12', maxChanges => 5 }), [], 'a well-typed changes');
is_deeply(bad('FileNode/changes', {}), ['sinceState'], 'sinceState is required');
is_deeply(bad('FileNode/changes', { sinceState => 12 }), ['sinceState'], 'and a string');
is_deeply(bad('FileNode/changes', { sinceState => '12', maxChanges => 0 }), ['maxChanges'], 'maxChanges must be positive (RFC 8620 S5.2)');
is_deeply(bad('FileNode/changes', { sinceState => '12', maxChanges => '5' }), ['maxChanges'], 'and a number');

# FileNode/set
is_deeply(bad('FileNode/set', { create => { a => {} }, update => { L1 => {} }, destroy => ['L2'],
                                onExists => 'rename', onDestroyRemoveChildren => JSON::true,
                                compareCaseInsensitively => JSON::false, ifInState => '3' }), [], 'a well-typed set');
is_deeply(bad('FileNode/set', { onExists => undef, create => undef, update => undef, destroy => undef }), [], 'every argument may be null');
is_deeply(bad('FileNode/set', { create => [ { name => 'x' } ] }), ['create'], 'create must be an object');
is_deeply(bad('FileNode/set', { update => 'L1' }), ['update'], 'update must be an object');
is_deeply(bad('FileNode/set', { destroy => 'L1' }), ['destroy'], 'destroy must be an array');
is_deeply(bad('FileNode/set', { destroy => [ ['L1'] ] }), ['destroy'], 'of strings');
is_deeply(bad('FileNode/set', { onExists => 'unchanged' }), ['onExists'], 'onExists unchanged needs JMAP-CONDITIONAL: not offered');
is_deeply(bad('FileNode/set', { onExists => 'bogus' }), ['onExists'], 'an unknown onExists');
is_deeply(bad('FileNode/set', { onExists => ['replace'] }), ['onExists'], 'onExists must be a string');
is_deeply(bad('FileNode/set', { onDestroyRemoveChildren => 1 }), ['onDestroyRemoveChildren'], 'onDestroyRemoveChildren must be a boolean');
is_deeply(bad('FileNode/set', { compareCaseInsensitively => 'true' }), ['compareCaseInsensitively'], 'compareCaseInsensitively must be a boolean');
is_deeply(bad('FileNode/set', { ifInState => 3 }), ['ifInState'], 'ifInState must be a string');

done_testing;
