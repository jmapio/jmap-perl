package JMAP::PDPA;
use strict;
use warnings;

# PDPA (Personal Data Portability Archive): an account's mail, contacts and
# calendars as a zip, and back.  Runs in the account's worker, where
# blocking is fine -- reading every message, zipping and unzipping used to
# run in the parent, whose event loop must never block.  Every request goes
# through $call->($command, $args), the worker's own command dispatch
# ('jmap', 'fetch_blobs', 'store_blob'), which dies on failure; so this is
# testable against a fake (t/pdpa.t).

use JSON::XS ();
use File::Temp ();
use POSIX qw(strftime);
use IO::Compress::Zip     qw($ZipError);
use IO::Uncompress::Unzip qw($UnzipError);

my $JSON = JSON::XS->new->utf8->canonical;

sub _jmap {
  my ($call, $cap, @calls) = @_;
  my $r = $call->('jmap', { using => ['urn:ietf:params:jmap:core', "urn:ietf:params:jmap:$cap"], methodCalls => \@calls });
  return { map { $_->[2] => $_->[1] } grep { $_->[0] ne 'error' } @{ $r->{methodResponses} || [] } };
}

# A zip entry name made from a name the user chose (a mailbox, address
# book or calendar): no "..", no leading "/", no empty segment.
sub _safe_path {
  my ($p) = @_;
  my @seg = grep { length && $_ ne '.' && $_ ne '..' } split m{/}, $p // '';
  return @seg ? join('/', @seg) : '_';
}

sub _mbox_path {
  my ($id, $map) = @_;
  my @parts;
  my %seen;
  while (my $m = $map->{$id}) {
    last if $seen{$id}++;
    unshift @parts, $m->{name};
    $id = $m->{parentId} // last;
  }
  return _safe_path(join '/', @parts);
}

# The archive, as zip bytes.
sub export {
  my (%o) = @_;
  my $call = $o{call};
  my %zip;
  $zip{'archive.json'} = $JSON->encode({
    archive => {
      id        => $o{uuid} // _uuid(),
      name      => "Export for $o{accountid}",
      generator => 'jmap-proxy',
      timestamp => strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($o{now} // time())),
      version   => '1',
    },
    dataset => { languagetag => 'en' },
  });
  _export_contacts($call, \%zip);
  _export_calendars($call, \%zip);
  _export_mail($call, \%zip);
  return _zip(%zip);
}

sub _uuid { require Data::UUID::LibUUID; return Data::UUID::LibUUID::new_uuid_string() }

sub _export_mail {
  my ($call, $zip) = @_;
  my $res = _jmap($call, 'mail', ['Mailbox/get', {}, 'mx']);
  my %mbox = map { $_->{id} => $_ } @{ $res->{mx}{list} || [] };
  my @ids;
  for (my $pos = 0; ; $pos += 1000) {
    my $q = _jmap($call, 'mail', ['Email/query', { position => $pos, limit => 1000 }, 'eq']);
    my @got = @{ $q->{eq}{ids} || [] };
    push @ids, @got;
    last if @got < 1000;
  }
  my %flag = ('$seen' => '\Seen', '$answered' => '\Answered', '$flagged' => '\Flagged', '$draft' => '\Draft');
  my %by_folder;
  # a page at a time, so no more than a page of messages is held at once
  while (my @page = splice(@ids, 0, 500)) {
    my $got = _jmap($call, 'mail', ['Email/get', { ids => \@page, properties => [qw(id mailboxIds keywords receivedAt)] }, 'eg']);
    my @emails = @{ $got->{eg}{list} || [] };
    next unless @emails;
    my $blobs = $call->('fetch_blobs', { ids => [ map { "m-$_->{id}" } @emails ] }) || {};
    for my $e (@emails) {
      my $b = $blobs->{"m-$e->{id}"} or next;
      my $raw = do { local $/; open(my $fh, '<:raw', $b->{path}) or next; <$fh> };
      unlink $b->{path} if $b->{is_temp};
      my ($mid) = sort keys %{ $e->{mailboxIds} || {} };
      my $folder = $mid ? _mbox_path($mid, \%mbox) : 'INBOX';
      push @{ $by_folder{$folder} }, [ $raw, [ map { $flag{lc $_} // "\$$_" } sort keys %{ $e->{keywords} || {} } ], $e->{receivedAt} ];
    }
  }
  for my $folder (sort keys %by_folder) {
    my (@items, $seq);
    for my $m (@{ $by_folder{$folder} }) {
      my $file = ++$seq . '.eml';
      $zip->{"mail/$folder/$file"} = $m->[0];
      push @items, { filename => $file, (@{ $m->[1] } ? (flags => $m->[1]) : ()), ($m->[2] ? (receivedAt => $m->[2]) : ()) };
    }
    $zip->{"mail/$folder/folder.json"} = $JSON->encode({ name => (split m{/}, $folder)[-1], items => \@items });
  }
}

sub _export_collections {
  my ($call, $zip, $top, $cap, $coll, $type, $filter) = @_;
  my $res = _jmap($call, $cap, ["$coll/get", {}, 'c']);
  for my $c (@{ $res->{c}{list} || [] }) {
    my $dir = _safe_path($c->{name} // $coll);
    my $got = _jmap($call, $cap,
      ["$type/query", { filter => { $filter => $c->{id} } }, 'q'],
      ["$type/get", { '#ids' => { resultOf => 'q', name => "$type/query", path => '/ids' } }, 'g']);
    my @items;
    for my $obj (@{ $got->{g}{list} || [] }) {
      my $uid = _safe_path($obj->{uid} // $obj->{id});
      $uid =~ s{/}{_}g;
      $zip->{"$top/$dir/$uid.json"} = $JSON->encode($obj);
      push @items, { filename => "$uid.json", uid => $obj->{uid} // $obj->{id} };
    }
    $zip->{"$top/$dir/folder.json"} = $JSON->encode({ name => $c->{name} // $dir, items => \@items });
  }
}

sub _export_contacts  { _export_collections(@_[0, 1], 'contacts',  'contacts',  'AddressBook', 'ContactCard',   'inAddressBook') }
sub _export_calendars { _export_collections(@_[0, 1], 'calendars', 'calendars', 'Calendar',    'CalendarEvent', 'inCalendar') }

sub _zip {
  my (%files) = @_;
  # archive.json first, then the rest in order
  my @paths = ('archive.json', sort grep { $_ ne 'archive.json' } keys %files);
  my $out = '';
  my $z = IO::Compress::Zip->new(\$out, Name => shift @paths) or die "zip: $ZipError\n";
  $z->print($files{'archive.json'} // '');
  for my $p (@paths) {
    $z->newStream(Name => $p) or die "zip: $ZipError\n";
    $z->print($files{$p});
  }
  $z->close();
  return $out;
}

# The files in zip bytes, as { name => content }.  Dies on a bad zip.
sub unzip {
  my ($bytes) = @_;
  # not Transparent: data that is not a zip is an error, not one plain file
  my $u = IO::Uncompress::Unzip->new(\$bytes, Transparent => 0) or die "not a zip: $UnzipError\n";
  my %files;
  my $status = 1;
  while ($status > 0) {
    my $h = $u->getHeaderInfo() or die "not a zip\n";
    my $name = $h->{Name};
    my $content = '';
    my $buf;
    while (($status = $u->read($buf)) > 0) { $content .= $buf }
    die "zip: $UnzipError\n" if $status < 0;
    $files{$name} = $content if defined $name && $name !~ m{/\z};
    $status = $u->nextStream();
  }
  die "zip: $UnzipError\n" if $status < 0;
  return %files;
}

# Bring an archive in, under $prefix (a mailbox/collection name prefix).
# Returns a count of what was imported.
sub import_archive {
  my (%o) = @_;
  my %files = unzip($o{zip});
  my %n = (emails => 0, contacts => 0, events => 0);
  $n{emails}   = _import_mail($o{call}, $o{prefix}, \%files, $o{tmpdir});
  $n{contacts} = _import_collections($o{call}, $o{prefix}, \%files, 'contacts', 'contacts', 'AddressBook', 'ContactCard', 'addressBookIds');
  $n{events}   = _import_collections($o{call}, $o{prefix}, \%files, 'calendars', 'calendars', 'Calendar', 'CalendarEvent', 'calendarIds');
  return \%n;
}

sub _import_mail {
  my ($call, $prefix, $files, $tmpdir) = @_;
  my %folders;
  for my $p (sort keys %$files) {
    next unless $p =~ m{^mail/(.+)/folder\.json\z};
    my $src = $1;
    my $meta = eval { JSON::XS::decode_json($files->{$p}) } || {};
    $folders{$src} = { meta => $meta, dest => _safe_path($prefix ? "$prefix/$src" : $src) };
  }
  return 0 unless %folders;

  my $res = _jmap($call, 'mail', ['Mailbox/get', {}, 'mx']);
  my %byid = map { $_->{id} => $_ } @{ $res->{mx}{list} || [] };
  my %path_id = map { (_mbox_path($_, \%byid) => $_) } keys %byid;
  my %want;
  for my $f (values %folders) {
    my @parts = split m{/}, $f->{dest};
    $want{ join '/', @parts[0 .. $_] } = 1 for 0 .. $#parts;
  }
  for my $path (sort { length $a <=> length $b || $a cmp $b } grep { !$path_id{$_} } keys %want) {
    my @parts = split m{/}, $path;
    my $parent = @parts > 1 ? $path_id{ join '/', @parts[0 .. $#parts - 1] } : undef;
    my $r = _jmap($call, 'mail', ['Mailbox/set', { create => { m => { name => $parts[-1], ($parent ? (parentId => $parent) : ()) } } }, 'mc']);
    $path_id{$path} = $r->{mc}{created}{m}{id} if $r->{mc}{created}{m};
  }

  my %kw = ('\Seen' => '$seen', '\Answered' => '$answered', '\Flagged' => '$flagged', '\Draft' => '$draft');
  my $n = 0;
  for my $src (sort keys %folders) {
    my $mbox = $path_id{ $folders{$src}{dest} } or next;
    for my $item (@{ $folders{$src}{meta}{items} || [] }) {
      my $raw = $files->{"mail/$src/" . ($item->{filename} // '')};
      next unless defined $raw;
      my $tmp = File::Temp->new(DIR => $tmpdir, UNLINK => 0);
      binmode $tmp;
      print $tmp $raw;
      close $tmp;
      my $blob = eval { $call->('store_blob', { path => $tmp->filename, type => 'message/rfc822', is_temp => 1 }) };
      unlink $tmp->filename if -e $tmp->filename;
      next unless $blob && $blob->{blobId};
      my %keywords = map { ($kw{$_} // lc(s/^\\//r)) => JSON::XS::true } grep { !/^\\Recent\z/i } @{ $item->{flags} || [] };
      my $r = _jmap($call, 'mail', ['Email/import', { emails => { e => {
        blobId => $blob->{blobId}, mailboxIds => { $mbox => JSON::XS::true }, keywords => \%keywords,
        ($item->{receivedAt} ? (receivedAt => $item->{receivedAt}) : ()) } } }, 'ei']);
      if ($r->{ei}{created}{e}) { $n++; next }
      # the message is in the account already (RFC 8621 S4.8 alreadyExists):
      # it goes into this folder too, so the folder is as it was archived
      my $nc = ($r->{ei}{notCreated} || {})->{e} || {};
      if (($nc->{type} // '') eq 'alreadyExists' && defined $nc->{existingId}) {
        my $u = _jmap($call, 'mail', ['Email/set', { update => { $nc->{existingId} => { "mailboxIds/$mbox" => JSON::XS::true } } }, 'eu']);
        $n++ if exists(($u->{eu}{updated} || {})->{ $nc->{existingId} });
      }
    }
  }
  return $n;
}

sub _import_collections {
  my ($call, $prefix, $files, $top, $cap, $coll, $type, $idsprop) = @_;
  my %dirs;
  for my $p (sort keys %$files) {
    next unless $p =~ m{^\Q$top\E/(.+)/folder\.json\z};
    $dirs{$1} = eval { JSON::XS::decode_json($files->{$p}) } || {};
  }
  my $n = 0;
  for my $dir (sort keys %dirs) {
    my $meta = $dirs{$dir};
    my $name = $meta->{name} // $dir;
    $name = "$prefix/$name" if $prefix;
    my $r = _jmap($call, $cap, ["$coll/set", { create => { c => { name => $name } } }, 's']);
    my $cid = $r->{s}{created}{c}{id} or next;
    my %create;
    for my $item (@{ $meta->{items} || [] }) {
      my $obj = eval { JSON::XS::decode_json($files->{"$top/$dir/" . ($item->{filename} // '')}) } or next;
      delete @{$obj}{ 'id', $idsprop };
      $obj->{$idsprop} = { $cid => JSON::XS::true };
      $create{ 'o' . scalar(keys %create) } = $obj;
    }
    next unless %create;
    my $s = _jmap($call, $cap, ["$type/set", { create => \%create }, 'o']);
    $n += keys %{ $s->{o}{created} || {} };
  }
  return $n;
}

1;
