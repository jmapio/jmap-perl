#!/usr/bin/perl
# t/filenode-sync.t -- ImapDB::sync_files against a synthetic WebDAV tree
# (backend_cmd replaced), for what Cyrus cannot show live: dead properties,
# a root the server will not describe, a listing gone stale during the walk,
# and backing off from a broken server.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON;
use lib '.';

$ENV{JMAP_DATADIR} = tempdir(CLEANUP => 1);
require JMAP::ImapDB;
require JMAP::API;

my $R = '/dav/drive/user/u';
my $T0 = 1_700_000_000;

# the fake server: href => entry
my %tree;
sub reset_tree {
  %tree = (
    $R           => { href => $R, isCollection => 1, etag => 'r1', modified => $T0, dead => {} },
    "$R/d"       => { href => "$R/d", isCollection => 1, etag => 'd1', modified => $T0, dead => {} },
    "$R/d/a.txt" => { href => "$R/d/a.txt", isCollection => 0, etag => 'a1', size => 5,
                      type => 'text/plain', modified => $T0 + 10, created => $T0,
                      dead => { modified => '2001-02-03T04:05:06Z', isSubscribed => 'false' } },
  );
}
my ($hide_root, $die, $during_walk, $calls) = (0, 0, undef, 0);

no warnings qw(redefine once);
*JMAP::ImapDB::backend_cmd = sub {
  my ($Self, $cmd, $path, $depth) = @_;
  die "in transaction\n" if $Self->in_transaction();
  $calls++;
  die "server down\n" if $die;
  die "unexpected $cmd" unless $cmd eq 'files_prop_find';
  $path =~ s{/\z}{};
  my $self = $tree{$path} or return [];
  return $hide_root && $path eq $R ? [] : [ { %$self } ] if $depth == 0;
  my @kids = map { +{ %{ $tree{$_} } } } sort grep { m{^\Q$path\E/[^/]+\z} } keys %tree;
  $during_walk->($Self) if $during_walk;
  return [ { %$self }, @kids ];
};
use warnings 'redefine';

my $db = JMAP::ImapDB->new('synctest');
# as in the worker: DB::commit only persists jhighestmodseq (and the jstate
# columns) when a change callback is set
$db->{change_cb} = sub {};
$db->begin();
$db->dinsert('iserver', { username => 'u', webdavURL => "http://dav.example$R/",
                          webdavFeatures => encode_json({ etagIsContent => 0, deadProps => 1 }) });   # the fake lists J: properties back
$db->commit();
my $api = JMAP::API->new($db);

sub rows {
  $db->begin();
  my $r = { map { $_->{href} => $_ } @{ $db->dget('jfilenodes', {}) } };
  $db->commit();
  return $r;
}
sub obj {
  my ($href) = @_;
  my $rows = rows();
  my %byid = map { $_->{nodeid} => $_ } values %$rows;
  return $api->_filenode_object($rows->{$href}, \%byid);
}

# --- first sync; dead properties are kept apart from the server's values
reset_tree();
is($db->first_files_sync(), 1, 'first_files_sync runs when no sync has happened');
my $rows = rows();
is(scalar keys %$rows, 3, 'root, directory and file mirrored');
my $a = $rows->{"$R/d/a.txt"};
is($a->{modified}, $T0 + 10, 'the modified column is the server getlastmodified');
is_deeply(decode_json($a->{deadprops}), { modified => '2001-02-03T04:05:06Z', isSubscribed => 'false' },
  'dead properties kept in deadprops');
my $o = obj("$R/d/a.txt");
is($o->{modified}, '2001-02-03T04:05:06Z', 'the object shows the client-set modified');
is($o->{created}, '2023-11-14T22:13:20Z', 'and the server created where no dead one exists');
ok(!$o->{isSubscribed}, 'dead isSubscribed overrides the default');
is($rows->{$R}{role}, 'home', 'root is home');
is($db->first_files_sync(), undef, 'first_files_sync does nothing once a sync has run');

# --- an external move of a file with a dead modified keeps its id
my $id = $a->{nodeid};
my $seq = $a->{jmodseq};
my $moved = delete $tree{"$R/d/a.txt"};
$tree{"$R/d/b.txt"} = { %$moved, href => "$R/d/b.txt", etag => 'a2' };   # Cyrus: ETag changes on MOVE
is($db->sync_files(), 1, 'sync after the move');
$rows = rows();
is($rows->{"$R/d/b.txt"}{nodeid}, $id, 'moved file keeps its id (size + server modified)');
ok($rows->{"$R/d/b.txt"}{active}, 'and is active');
ok($rows->{"$R/d/b.txt"}{jmodseq} > $seq, 'and is changed');
is(scalar(grep { $_->{active} } values %$rows), 3, 'nothing created or destroyed');

# --- a dead property change is a change; an idle sync is not
$seq = $rows->{"$R/d/b.txt"}{jmodseq};
$db->sync_files();
is(rows()->{"$R/d/b.txt"}{jmodseq}, $seq, 'an idle sync changes nothing');
$tree{"$R/d/b.txt"}{dead} = { modified => '2001-02-03T04:05:06Z', note => "caf\x{e9} \x{4e2d}" };
$db->sync_files();
ok(rows()->{"$R/d/b.txt"}{jmodseq} > $seq, 'a changed dead property is a change');
ok(obj("$R/d/b.txt")->{isSubscribed}, 'and isSubscribed is back to the default');
$seq = rows()->{"$R/d/b.txt"}{jmodseq};
$db->sync_files();
is(rows()->{"$R/d/b.txt"}{jmodseq}, $seq, 'non-ASCII dead properties compare equal on the next sync');

# --- a root the server will not describe at Depth 0 does not flap
my $root = rows()->{$R};
$hide_root = 1;
$tree{$R}{etag} = 'r2';
$db->sync_files();
my $root2 = rows()->{$R};
is($root2->{etag}, $root->{etag}, 'synthesised root leaves the row etag alone');
is($root2->{modified}, $root->{modified}, 'and its modified');
is($root2->{jmodseq}, $root->{jmodseq}, 'and its modseq');
$hide_root = 0;

# --- a listing that went stale during the walk is not applied
# A proxy write lands while the walk is under way: the new node is in the
# mirror but missing from this listing.  Applying the listing would destroy it.
my $proxyid = 'L' . ('f' x 32);
my $fired = 0;
$during_walk = sub {
  my ($Self) = @_;
  return if $fired++;
  $Self->begin();
  $Self->dmake('jfilenodes', { nodeid => $proxyid, parentid => $root->{nodeid}, name => 'new.txt',
                               href => "$R/new.txt", nodetype => 'file', size => 1, etag => 'n1',
                               modified => $T0 + 20, type => 'text/plain', changed => time() });
  $Self->commit();
  $tree{"$R/new.txt"} = { href => "$R/new.txt", isCollection => 0, etag => 'n1', size => 1,
                          type => 'text/plain', modified => $T0 + 20, dead => {} };
};
$calls = 0;
is($db->sync_files(), 1, 'sync with a write during the walk');
$during_walk = undef;
my $calls_per_walk = 3;   # Depth 0, then Depth 1 of each collection (root, d)
is($calls, 2 * $calls_per_walk, 'the stale listing was thrown away and the tree walked again');
$rows = rows();
is($rows->{"$R/new.txt"}{nodeid}, $proxyid, 'the proxy-written node keeps its id');
ok($rows->{"$R/new.txt"}{active}, 'and was not destroyed');

# --- a broken server is not hammered
$die = 1;
$db->begin(); $db->dupdate('iserver', { lastfilesync => 0 }); $db->commit();
$calls = 0;
{
  my $warned;
  local $SIG{__WARN__} = sub { $warned .= $_[0] };
  is($db->sync_files_if_due(60), 0, 'a failing sync reports failure');
  like($warned, qr/sync_files: server down/, 'and warns');
}
ok(!$db->in_transaction(), 'no transaction left open');
$db->begin(); my $last = $db->dgetfield('iserver', {}, 'lastfilesync'); $db->commit();
ok(time() - $last < 5, 'the failed attempt is recorded');
$calls = 0;
$db->sync_files_if_due(60);
is($calls, 0, 'so the next call within the minute does not walk again');
$die = 0;

# --- a never-synced account: the background sync leaves the first walk to
# the backfill worker; a FileNode request does it if it is still undone
$db->begin(); $db->dupdate('iserver', { lastfilesync => undef }); $db->commit();
$calls = 0;
$db->sync_files_if_due(300, { first => 0 });
is($calls, 0, 'background sync skips an account that has never synced its files');
$db->sync_files_if_due(300);
is($calls, 0, 'and so does the default');
is($db->sync_files_if_due(60, { first => 1 }), 1, 'the on-demand sync runs the first walk');
ok($calls > 0, 'with backend calls');

# --- a sync that gives up on a mirror that keeps changing backs off too
$db->begin(); $db->dupdate('iserver', { lastfilesync => 0 }); $db->commit();
my $n = 0;
$during_walk = sub {
  my ($Self) = @_;
  return if $n++ % 2;   # once per walk: a write lands during every walk
  $Self->begin();
  $Self->ddirty('jfilenodes', { changed => time() }, { nodeid => $proxyid });
  $Self->commit();
};
{
  my $warned;
  local $SIG{__WARN__} = sub { $warned .= $_[0] };
  is($db->sync_files_if_due(60), 0, 'a sync that keeps finding a changed mirror gives up');
  like($warned, qr/changed during every walk/, 'and warns');
}
$during_walk = undef;
$db->begin(); $last = $db->dgetfield('iserver', {}, 'lastfilesync'); $db->commit();
ok(time() - $last < 5, 'the attempt is recorded for back-off');

# --- a server that does not store dead properties (Cyrus): the client
# values FileNode/set keeps in the mirror's deadprops are the only copy, and
# a listing (which has none) must not wipe them
$db->begin();
$db->dupdate('iserver', { webdavFeatures => encode_json({ etagIsContent => 0, deadProps => 0 }) });
my $bid = $db->dgetfield('jfilenodes', { href => "$R/d/b.txt", active => 1 }, 'nodeid');
$db->ddirty('jfilenodes', { deadprops => JMAP::FileNode::dead_json({ executable => 1 }) }, { nodeid => $bid });
$db->commit();
delete $db->{_filefeatures};
$tree{"$R/d/b.txt"}{dead} = {};
$seq = rows()->{"$R/d/b.txt"}{jmodseq};
is($db->sync_files(), 1, 'sync against a server without dead properties');
is_deeply(decode_json(rows()->{"$R/d/b.txt"}{deadprops} // 'null'), { executable => 1 }, 'mirror-only dead properties survive');
is(rows()->{"$R/d/b.txt"}{jmodseq}, $seq, 'and the sync is idle');
ok(obj("$R/d/b.txt")->{executable}, 'the object still shows them');

done_testing;
