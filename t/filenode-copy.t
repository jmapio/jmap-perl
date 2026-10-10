#!/usr/bin/perl
# t/filenode-copy.t -- JMAP::FileNodeCopy (cross-account FileNode/copy)
# against an in-memory fake of the two accounts' workers.
use strict;
use warnings;
use Test::More;
use JSON;
use lib '.';
use JMAP::FileNodeCopy;

# --- pure helpers
is_deeply([ JMAP::FileNodeCopy::chunks(2, 1 .. 5) ], [ [1, 2], [3, 4], [5] ], 'chunks');
is_deeply([ JMAP::FileNodeCopy::chunks(undef, 1 .. 3) ], [ [1, 2, 3] ], 'chunks: no max is the default');
{
  my $l = { ids => [] };
  my $q = sub { ['FileNode/query', { @_ }, 'q'] };
  is(JMAP::FileNodeCopy::add_page($l, $q->(ids => [1, 2], total => 5, position => 0, queryState => 's')), 'more', 'a first page');
  is(JMAP::FileNodeCopy::next_position($l), 2, 'next position');
  is(JMAP::FileNodeCopy::add_page($l, $q->(ids => [3, 4, 5], total => 5, position => 2, queryState => 's')), 'done', 'the last page');
  is_deeply($l->{ids}, [1 .. 5], 'all the ids');
  like(JMAP::FileNodeCopy::add_page({ ids => [] }, $q->(ids => [1], position => 0)), qr/how many/, 'no total: a failure');
  like(JMAP::FileNodeCopy::add_page({ ids => [1], total => 3, state => 's' }, $q->(ids => [2], total => 3, position => 1, queryState => 't')),
       qr/changed/, 'the query state moved between pages');
  like(JMAP::FileNodeCopy::add_page({ ids => [1], total => 3, state => 's' }, $q->(ids => [], total => 3, position => 1, queryState => 's')),
       qr/stopped/, 'an empty page short of the total');
  like(JMAP::FileNodeCopy::add_page({ ids => [] }, ['error', { type => 'unsupportedSort' }, 'q']), qr/could not be listed/, 'an error');
}

# --- the fake: two accounts, each a tree of nodes
my %acct;
my @log;
sub fresh {
  my %a = (state => 1, n => 0, pagecap => 1000, maxget => 1000, refuse => {}, nodes => {}, blobs => {});
  $a{nodes}{home} = { id => 'home', parentId => undef, name => '', nodeType => 'directory' };
  return \%a;
}
sub mk {
  my ($ac, $parent, $name, $content, %p) = @_;
  my $id = $p{id} // ('x' . ++$ac->{n});
  $ac->{nodes}{$id} = { id => $id, parentId => $parent, name => $name,
                       nodeType => defined $content ? 'file' : 'directory', %p };
  if (defined $content) { $ac->{nodes}{$id}{blobId} = "d-$id"; $ac->{blobs}{"d-$id"} = $content }
  $ac->{state}++;
  return $id;
}
sub kids { my ($ac, $id) = @_; sort { $ac->{nodes}{$a}{name} cmp $ac->{nodes}{$b}{name} } grep { ($ac->{nodes}{$_}{parentId} // '') eq $id } keys %{ $ac->{nodes} } }
sub tree { my ($ac, $id) = @_; map { ($_, tree($ac, $_)) } sort { $ac->{nodes}{$a}{name} cmp $ac->{nodes}{$b}{name} } grep { ($ac->{nodes}{$_}{parentId} // '') eq $id } keys %{ $ac->{nodes} } }
sub destroy_one {
  my ($ac, $id) = @_;
  delete $ac->{nodes}{$_} for tree($ac, $id), $id;
}
sub fset {
  my ($ac, $args) = @_;
  my $old = $ac->{state};
  return ['error', { type => 'stateMismatch' }] if defined $args->{ifInState} && $args->{ifInState} ne $old;
  my (%created, %nc, %updated, %nu, @destroyed, %nd);
  my $clash = sub {
    my ($pid, $name, $self) = @_;
    my ($c) = grep { $_ ne ($self // '') && ($ac->{nodes}{$_}{parentId} // '') eq $pid && $ac->{nodes}{$_}{name} eq $name } keys %{ $ac->{nodes} };
    return $c;
  };
  my $make_room = sub {   # onExists: returns an error, or undef with the way clear
    my ($pid, $name, $self) = @_;
    my $c = $clash->($pid, $name, $self) or return undef;
    return { type => 'alreadyExists', existingId => $c } unless ($args->{onExists} // '') eq 'replace';
    return { type => 'nodeHasChildren' } if tree($ac, $c) && !$args->{onDestroyRemoveChildren};
    push @destroyed, tree($ac, $c), $c;
    destroy_one($ac, $c);
    return undef;
  };
  my %cr = %{ $args->{create} || {} };
  my $more = 1;
  while ($more) {
    $more = 0;
    for my $k (sort keys %cr) {
      my $c = $cr{$k};
      my $pid = $c->{parentId};
      if (defined $pid && $pid =~ /^#(.+)/) {
        if ($nc{$1})         { $nc{$k} = { type => 'invalidProperties', properties => ['parentId'] }; delete $cr{$k}; $more = 1; next }
        next unless $created{$1};
        $pid = $created{$1}{id};
      }
      delete $cr{$k}; $more = 1;
      if (!defined $pid || !$ac->{nodes}{$pid}) { $nc{$k} = { type => 'invalidProperties', properties => ['parentId'] }; next }
      if ($ac->{refuse}{ $c->{name} }) { $nc{$k} = { type => 'forbidden' }; next }
      if (my $e = $make_room->($pid, $c->{name})) { $nc{$k} = $e; next }
      my $id = 'y' . ++$ac->{n};
      my $content = defined $c->{blobId} ? $ac->{blobs}{ $c->{blobId} } : undef;
      if (($c->{nodeType} // '') eq 'file' && !defined $content) { $nc{$k} = { type => 'invalidProperties', properties => ['blobId'] }; next }
      $ac->{nodes}{$id} = { %$c, id => $id, parentId => $pid, (defined $content ? (blobId => "d-$id") : ()) };
      $ac->{blobs}{"d-$id"} = $content if defined $content;
      $created{$k} = { id => $id };
    }
  }
  $nc{$_} = { type => 'invalidProperties', properties => ['parentId'] } for keys %cr;
  for my $id (sort keys %{ $args->{update} || {} }) {
    my $n = $ac->{nodes}{$id} or do { $nu{$id} = { type => 'notFound' }; next };
    my $p = $args->{update}{$id};
    if (my $e = $make_room->($n->{parentId}, $p->{name}, $id)) { $nu{$id} = $e; next }
    $n->{name} = $p->{name};
    $updated{$id} = undef;
  }
  my $depth = sub { my $d = 0; for (my $x = $_[0]; $ac->{nodes}{$x} && defined $ac->{nodes}{$x}{parentId}; $x = $ac->{nodes}{$x}{parentId}) { $d++ } $d };
  my %dep = map { ($_ => $depth->($_)) } @{ $args->{destroy} || [] };
  for my $id (sort { $dep{$b} <=> $dep{$a} } keys %dep) {
    $ac->{nodes}{$id} or do { $nd{$id} = { type => 'notFound' }; next };
    if (!$args->{onDestroyRemoveChildren} && kids($ac, $id)) { $nd{$id} = { type => 'nodeHasChildren' }; next }
    push @destroyed, tree($ac, $id), $id;
    destroy_one($ac, $id);
  }
  $ac->{state}++ if %created || %updated || @destroyed;
  my $ne = sub { %{ $_[0] } ? $_[0] : undef };
  return ['FileNode/set', { accountId => $args->{accountId}, oldState => "$old", newState => "$ac->{state}",
    created => $ne->(\%created), notCreated => $ne->(\%nc), updated => $ne->(\%updated), notUpdated => $ne->(\%nu),
    destroyed => (@destroyed ? [ do { my %s; grep { !$s{$_}++ } @destroyed } ] : undef), notDestroyed => $ne->(\%nd) }];
}
sub fcall {
  my ($ac, $m, $args) = @_;
  if ($m eq 'FileNode/get') {
    my @ids = @{ $args->{ids} || [] };
    return ['error', { type => 'requestTooLarge' }] if @ids > $ac->{maxget};
    return ['FileNode/get', { state => "$ac->{state}", list => [ map { +{ %{ $ac->{nodes}{$_} } } } grep { $ac->{nodes}{$_} } @ids ],
                              notFound => [ grep { !$ac->{nodes}{$_} } @ids ] }];
  }
  if ($m eq 'FileNode/query') {
    my @all = tree($ac, $args->{filter}{ancestorId});
    my $total = @all;
    my $pos = $args->{position} // 0;
    my @ids = grep { defined } @all[ $pos .. $pos + $ac->{pagecap} - 1 ];
    return ['FileNode/query', { queryState => "$ac->{state}", position => $pos, ids => \@ids,
                                ($args->{calculateTotal} && !$ac->{nototal} ? (total => $total) : ()) }];
  }
  return fset($ac, $args) if $m eq 'FileNode/set';
  die "fake: $m";
}
my $send = sub {
  my ($aid, $cmd, $args, $cb, $errcb) = @_;
  my $ac = $acct{$aid};
  push @log, [ $aid, $cmd, $cmd eq 'jmap' ? [ map { [ $_->[0], $_->[1] ] } @{ $args->{methodCalls} } ] : $args ];
  if ($cmd eq 'jmap') {
    return $cb->({ methodResponses => [ map { my $r = fcall($ac, $_->[0], $_->[1]); [ @$r, $_->[2] ] } @{ $args->{methodCalls} } ] });
  }
  if ($cmd eq 'fetch_blobs') {
    return $cb->({ map { ($_ => ($ac->{toobig}{$_} ? { error => "fileTooLarge: the file is 9 bytes, over JMAP_FILES_MAX_BYTES (8)" }
                              : defined $ac->{blobs}{$_} && !$ac->{stale}{$_} ? { path => "mem:$_", content => $ac->{blobs}{$_} } : undef)) } @{ $args->{ids} } });
  }
  if ($cmd eq 'store_blob') {
    my $bid = 'f-' . ++$ac->{n};
    $ac->{blobs}{$bid} = $args->{content};
    return $cb->({ blobId => $bid });
  }
  if ($cmd eq 'session_caps') {
    return $errcb->('not passthrough') unless $ac->{caps};
    return $cb->({ capabilities => { 'urn:ietf:params:jmap:core' => { maxObjectsInGet => $ac->{maxget} } } });
  }
  die "fake: $cmd";
};
sub run_copy {
  my (%args) = @_;
  my $ids = delete $args{created_ids};
  my $out;
  JMAP::FileNodeCopy::copy(send => $send, args => { fromAccountId => 'A', accountId => 'B', %args },
    from => 'A', to => 'B', tag => 't', cb => sub { $out = shift }, errcb => sub { $out = [ 'errcb', $_[0] ] },
    created_ids => $ids);
  return $out;
}
sub names { my ($ac, $id) = @_; [ map { my $p = $ac->{nodes}{$_}; my @n; for (my $x = $_; $x && $x ne $id; $x = $ac->{nodes}{$x}{parentId}) { unshift @n, $ac->{nodes}{$x}{name} } join '/', @n } tree($ac, $id) ] }

# a tree: d/{a.txt, sub/{b.txt}}
sub setup {
  %acct = (A => fresh(), B => fresh());
  my $A = $acct{A};
  my $d = mk($A, 'home', 'd', undef, id => 'D');
  mk($A, $d, 'a.txt', 'aaa', id => 'FA', type => 'text/plain', executable => JSON::true);
  my $sub = mk($A, $d, 'sub', undef, id => 'SUB');
  mk($A, $sub, 'b.txt', 'bbb', id => 'FB');
  mk($A, 'home', 'lone.txt', 'lll', id => 'LONE');
  @log = ();
}

setup();
my $r = run_copy(create => { c => { id => 'D', parentId => 'home' }, bad => { name => 'x' }, nf => { id => 'nope', parentId => 'home' } });
is($r->[0], 'FileNode/copy', 'a FileNode/copy answer');
ok($r->[1]{created}{c}{id}, 'the directory copied');
is_deeply(names($acct{B}, 'home'), [ 'd', 'd/a.txt', 'd/sub', 'd/sub/b.txt' ], 'its whole tree');
is($r->[1]{notCreated}{bad}{type}, 'invalidProperties', 'no id: invalidProperties');
is_deeply($r->[1]{notCreated}{bad}{properties}, ['id'], 'naming id');
is($r->[1]{notCreated}{nf}{type}, 'notFound', 'an unknown source: notFound');
my ($ca) = grep { $_->{name} eq 'a.txt' } values %{ $acct{B}{nodes} };
is($ca->{executable}, JSON::true, 'executable carried');
is($ca->{type}, 'text/plain', 'type carried');
is($acct{B}{blobs}{ $ca->{blobId} }, 'aaa', 'content carried');
my ($q) = grep { $_->[1] eq 'jmap' && $_->[2][1][0] eq 'FileNode/query' } @log;
is($q->[2][1][1]{calculateTotal}, JSON::true, 'the source query asks for the total');

# paging: three nodes a page, and gets of at most two
setup();
$acct{A}{pagecap} = 1;
$acct{A}{maxget} = 2;
$acct{A}{caps} = 1;
{
  local $JMAP::FileNodeCopy::DEFAULT_MAX_GET = 2;
  $r = run_copy(create => { c => { id => 'D', parentId => 'home' } });
}
ok($r->[1]{created}{c}, 'a paged listing copies') or diag explain $r;
is_deeply(names($acct{B}, 'home'), [ 'd', 'd/a.txt', 'd/sub', 'd/sub/b.txt' ], 'all of it');
my @pos = map { $_->[1]{position} } grep { $_->[0] eq 'FileNode/query' } map { @{ $_->[2] } } grep { $_->[1] eq 'jmap' } @log;
is_deeply(\@pos, [0, 1, 2], 'one page at a time, by position');
my @gets = map { scalar @{ $_->[1]{ids} } } grep { $_->[0] eq 'FileNode/get' } map { @{ $_->[2] } } grep { $_->[1] eq 'jmap' } @log;
ok(!(grep { $_ > 2 } @gets), 'no get larger than maxObjectsInGet') or diag explain \@gets;
ok((grep { $_->[1] eq 'session_caps' } @log), 'the limit read from the session');

# a source that gives no total: the item fails, nothing is written
setup();
$acct{A}{nototal} = 1;
$r = run_copy(create => { c => { id => 'D', parentId => 'home' }, l => { id => 'LONE', parentId => 'home' } });
like($r->[1]{notCreated}{c}{description}, qr/how many/, 'no total: the item fails') or diag explain $r;
ok($r->[1]{created}{l}, 'a file needs no listing');
is_deeply(names($acct{B}, 'home'), [ 'lone.txt' ], 'nothing of the directory written');

# a file changed underneath: the item fails before the destination is touched
setup();
$acct{A}{stale}{'d-FB'} = 1;
$r = run_copy(create => { c => { id => 'D', parentId => 'home' } });
like($r->[1]{notCreated}{c}{description}, qr{d/sub/b\.txt}, 'a stale blob fails the item, naming it') or diag explain $r;
ok(!(grep { $_->[0] eq 'B' && $_->[1] eq 'jmap' && grep { $_->[0] eq 'FileNode/set' && %{ $_->[1]{create} || {} } } @{ $_->[2] } } @log),
   'the destination saw no creates');

# a file the source refuses to read (over JMAP_FILES_MAX_BYTES): the item
# fails with the source's reason; the rest of the call goes ahead
setup();
$acct{A}{toobig}{'d-FB'} = 1;
$r = run_copy(create => { c => { id => 'D', parentId => 'home' }, l => { id => 'LONE', parentId => 'home' } });
is($r->[1]{notCreated}{c}{type}, 'serverFail', 'a blob over the cap fails the item: serverFail') or diag explain $r;
like($r->[1]{notCreated}{c}{description}, qr{JMAP_FILES_MAX_BYTES}, 'with the reason');
like($r->[1]{notCreated}{c}{description}, qr{d/sub/b\.txt}, 'naming the file');
ok($r->[1]{created}{l}, 'the other item is copied') or diag explain $r;
ok(!(grep { $_->[0] eq 'B' && $_->[1] eq 'store_blob' && ($_->[2]{error} // '') } @log), 'nothing refused was stored');

# the destination refuses part of the tree: rolled back by explicit ids, a
# file someone else put in it meanwhile is not lost
setup();
$acct{B}{refuse}{'b.txt'} = 1;
$r = run_copy(create => { c => { id => 'D', parentId => 'home' } });
like($r->[1]{notCreated}{c}{description}, qr{d/sub/b\.txt: forbidden}, 'a partial copy is notCreated, naming the refused node') or diag explain $r;
is_deeply(names($acct{B}, 'home'), [], 'and nothing of it is left');
my ($rb) = grep { $_->[0] eq 'FileNode/set' && $_->[1]{destroy} } map { @{ $_->[2] } } grep { $_->[0] eq 'B' && $_->[1] eq 'jmap' } @log;
ok($rb && !$rb->[1]{onDestroyRemoveChildren}, 'the rollback names its nodes, without onDestroyRemoveChildren') or diag explain $rb;
is(scalar @{ $rb->[1]{destroy} }, 3, 'the three nodes it made');

# onExists replace of a directory with contents: staged, then renamed
setup();
my $old = mk($acct{B}, 'home', 'd', undef, id => 'OLD');
mk($acct{B}, $old, 'keep.txt', 'kkk', id => 'KEEP');
$r = run_copy(onExists => 'replace', onDestroyRemoveChildren => JSON::true, create => { c => { id => 'D', parentId => 'home' } });
ok($r->[1]{created}{c}, 'replace: copied') or diag explain $r;
is_deeply(names($acct{B}, 'home'), [ 'd', 'd/a.txt', 'd/sub', 'd/sub/b.txt' ], 'the old directory replaced');
is_deeply([ sort @{ $r->[1]{destroyed} || [] } ], [ 'KEEP', 'OLD' ], 'and listed as destroyed');
my ($stage) = grep { $_->[0] eq 'FileNode/set' && $_->[1]{create} } map { @{ $_->[2] } } grep { $_->[0] eq 'B' && $_->[1] eq 'jmap' } @log;
my ($top) = grep { !(($_->{parentId} // '') =~ /^#/) } values %{ $stage->[1]{create} };
like($top->{name}, qr/^\.jmap-copy-/, 'created under a staging name');

# ... and when part of it fails, the old directory survives
setup();
$old = mk($acct{B}, 'home', 'd', undef, id => 'OLD');
mk($acct{B}, $old, 'keep.txt', 'kkk', id => 'KEEP');
$acct{B}{refuse}{'b.txt'} = 1;
$r = run_copy(onExists => 'replace', onDestroyRemoveChildren => JSON::true, create => { c => { id => 'D', parentId => 'home' } });
ok($r->[1]{notCreated}{c}, 'replace with a partial failure: notCreated') or diag explain $r;
is_deeply(names($acct{B}, 'home'), [ 'd', 'd/keep.txt' ], 'the old directory survives, and no staging tree is left');

# ... and when the rename fails (the old one has children, no
# onDestroyRemoveChildren), the rename's error, the old one kept
setup();
$old = mk($acct{B}, 'home', 'd', undef, id => 'OLD');
mk($acct{B}, $old, 'keep.txt', 'kkk', id => 'KEEP');
$r = run_copy(onExists => 'replace', create => { c => { id => 'D', parentId => 'home' } });
is($r->[1]{notCreated}{c}{type}, 'nodeHasChildren', 'a failed rename: its error') or diag explain $r;
is_deeply(names($acct{B}, 'home'), [ 'd', 'd/keep.txt' ], 'the old directory survives');

# two items to one name with replace: the later fails up front
setup();
$r = run_copy(onExists => 'replace', create => { a => { id => 'LONE', parentId => 'home', name => 'x' },
                                                 b => { id => 'FA', parentId => 'home', name => 'x' } });
ok($r->[1]{created}{a}, 'the first goes ahead') or diag explain $r;
is($r->[1]{notCreated}{b}{type}, 'alreadyExists', 'the second: alreadyExists');
is($r->[1]{notCreated}{b}{existingId}, $r->[1]{created}{a}{id}, 'naming the first copy');

# creation ids from earlier in the request
setup();
$r = run_copy(created_ids => { dir => 'D', there => 'home' }, create => { c => { id => '#dir', parentId => '#there' } });
ok($r->[1]{created}{c}, '#references resolve from createdIds') or diag explain $r;
$r = run_copy(create => { c => { id => 'LONE', parentId => '#nosuch' } });
is($r->[1]{notCreated}{c}{type}, 'invalidProperties', 'an unknown creation id: invalidProperties');

# ifFromInState / ifInState
setup();
$r = run_copy(ifFromInState => 'bogus', create => { c => { id => 'LONE', parentId => 'home' } });
is_deeply([ $r->[0], $r->[1]{type} ], [ 'error', 'stateMismatch' ], 'ifFromInState mismatch');
$r = run_copy(ifInState => 'bogus', create => { c => { id => 'LONE', parentId => 'home' } });
is_deeply([ $r->[0], $r->[1]{type} ], [ 'error', 'stateMismatch' ], 'ifInState mismatch');

# onSuccessDestroyOriginal: every node listed, no onDestroyRemoveChildren
setup();
$r = run_copy(onSuccessDestroyOriginal => JSON::true, create => { c => { id => 'D', parentId => 'home' } });
is(ref $r->[0], 'ARRAY', 'two answers') or diag explain $r;
is_deeply([ $r->[1][0], $r->[1][2] ], [ 'FileNode/set', 't' ], 'the implicit set, with the call id');
is_deeply([ sort @{ $r->[1][1]{destroyed} } ], [ sort qw(D FA SUB FB) ], 'the whole source tree destroyed');
is_deeply(names($acct{A}, 'home'), [ 'lone.txt' ], 'gone from the source');
setup();
$r = run_copy(onSuccessDestroyOriginal => JSON::true, destroyFromIfInState => 'bogus', create => { c => { id => 'D', parentId => 'home' } });
is_deeply([ $r->[1][0], $r->[1][1]{type}, $r->[1][2] ], [ 'error', 'stateMismatch', 't' ], 'destroyFromIfInState mismatch: the implicit set\'s error');
ok($acct{A}{nodes}{D}, 'and the source stays');
# a source that fails to answer the destroy is not silent
setup();
{
  my $orig = $send;
  my $flaky = sub { my @a = @_; return $a[4]->('gone away') if $a[0] eq 'A' && $a[1] eq 'jmap' && grep { $_->[1]{destroy} } @{ $a[2]{methodCalls} }; $orig->(@a) };
  my $out;
  JMAP::FileNodeCopy::copy(send => $flaky, args => { fromAccountId => 'A', accountId => 'B', onSuccessDestroyOriginal => JSON::true,
    create => { c => { id => 'LONE', parentId => 'home' } } }, from => 'A', to => 'B', tag => 't', cb => sub { $out = shift }, errcb => sub { $out = $_[0] });
  is_deeply([ $out->[1][0], $out->[1][1]{type}, $out->[1][2] ], [ 'error', 'serverFail', 't' ], 'a lost implicit destroy is reported') or diag explain $out;
}

# the staging rename's answer lost: look before taking anything back
for my $case ([ 'done', 1 ], [ 'not done', 0 ]) {
  my ($what, $run) = @$case;
  setup();
  my $old = mk($acct{B}, 'home', 'd', undef, id => 'OLD');
  my $out;
  my $lossy = sub {
    my @a = @_;
    if ($a[0] eq 'B' && $a[1] eq 'jmap' && grep { $_->[1]{update} } @{ $a[2]{methodCalls} }) {
      $send->(@a[0 .. 2], sub {}, sub {}) if $run;   # the rename happens (or not), the answer is lost
      return $a[4]->('connection reset');
    }
    $send->(@a);
  };
  JMAP::FileNodeCopy::copy(send => $lossy, args => { fromAccountId => 'A', accountId => 'B', onExists => 'replace',
    onDestroyRemoveChildren => JSON::true, create => { c => { id => 'D', parentId => 'home' } } },
    from => 'A', to => 'B', tag => 't', cb => sub { $out = shift }, errcb => sub { $out = $_[0] });
  if ($run) {
    ok($out->[1]{created}{c}, "a lost answer to a rename that was $what: created") or diag explain $out;
    is_deeply(names($acct{B}, 'home'), [ 'd', 'd/a.txt', 'd/sub', 'd/sub/b.txt' ], 'and in place');
  }
  else {
    like($out->[1]{notCreated}{c}{description} // '', qr/connection reset/, "a lost answer to a rename $what: notCreated") or diag explain $out;
    is_deeply(names($acct{B}, 'home'), [ 'd' ], 'the staged copy taken back, the old one kept');
  }
}

done_testing;
