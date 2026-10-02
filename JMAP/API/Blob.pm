#!/usr/bin/perl -cw

use strict;
use warnings;

# Blob methods for IMAP-backed accounts.
#
#   RFC 9404 (urn:ietf:params:jmap:blob):   Blob/upload, Blob/get, Blob/lookup
#   draft-ietf-jmap-blobext (urn:ietf:params:jmap:blob2):
#                                            Blob/set, Blob/get, Blob/lookup,
#                                            Blob/convert
#
# Blob/copy is RFC 8620 core and is orchestrated by the parent (jmap-proxy.pl).
# Passthrough accounts never reach this code: their batches are forwarded to
# the upstream, which answers with its own blob support.
#
# Each method is "selected by" its capability (RFC 9404 Section 4, blobext
# Sections 4-8); JMAP::Dispatch::method_capability_missing enforces that before
# dispatch. Blob/get still looks at "using" itself: the chunks and imageData
# properties exist only under blob2.
#
# Blob ids are the proxy's existing ones: "f-<jfileid>" for blobs created by
# upload, Blob/upload, Blob/set or Blob/convert (the jfiles table plus the
# files/ directory, expiring after a week unless referenced), and
# "m-<msgid>[-<part>]" for a message or one of its parts.

package JMAP::API;

use JMAP::BlobConvert;
use Encode ();
use MIME::Base64 ();
use Data::JSEmail ();

my $BLOB  = 'urn:ietf:params:jmap:blob';
my $BLOB2 = 'urn:ietf:params:jmap:blob2';
my $MAIL  = 'urn:ietf:params:jmap:mail';

my $BLOB_LIFETIME = 7 * 86400;
my %LOOKUP_TYPES = map { $_ => $MAIL } qw(Email Thread Mailbox);
my %DIGEST_OK    = map { $_ => 1 } @JMAP::BlobConvert::DIGEST_ALGORITHMS;

# The RFC 9404 slice of accountCapabilities; blob2 extends it.
sub blob_account_capabilities {
  my %rfc9404 = (
    maxSizeBlobSet            => $JMAP::BlobConvert::MAX_SIZE_BLOB_SET,
    maxDataSources            => $JMAP::BlobConvert::MAX_DATA_SOURCES,
    supportedTypeNames        => [ sort keys %LOOKUP_TYPES ],
    supportedDigestAlgorithms => [ @JMAP::BlobConvert::DIGEST_ALGORITHMS ],
  );
  return (
    $BLOB  => { %rfc9404 },
    $BLOB2 => {
      %rfc9404,
      uploadUrl => undef,   # the session-level uploadUrl serves every account
      chunkSize => undef,   # blobs are stored whole; any chunking is accepted
      %{ JMAP::BlobConvert::capabilities() },
    },
  );
}

# ── capability gating ───────────────────────────────────────────────────────

sub _blob_using {
  my ($Self, $cap) = @_;
  return $Self->{using} && $Self->{using}{$cap} ? 1 : 0;
}

sub _blob_init {
  my ($Self, $args) = @_;
  $Self->begin();
  my $accountid = $Self->{db}->accountid();
  $Self->commit();
  return (undef) if $args->{accountId} && $args->{accountId} ne $accountid;
  return ($accountid);
}

# ── blob access ─────────────────────────────────────────────────────────────

# ($type, $octets) for a blobId, or () when it does not exist.
sub _blob_fetch {
  my ($Self, $blobId) = @_;
  return () unless defined $blobId && length $blobId;
  my ($type, $content) = eval { $Self->{db}->get_blob($blobId) };
  return () unless defined $content;
  return ($type, $content);
}

# Store octets as a new blob; returns the BlobObject { id, type, size, expires }.
sub _blob_store {
  my ($Self, $accountid, $type, $octets, $noPersist) = @_;
  $type = JMAP::BlobConvert::detect_type($octets) // 'application/octet-stream'
    unless defined $type && length $type;
  my $r = $Self->{db}->put_file($accountid, $type, $octets);
  return {
    id      => $r->{blobId},
    type    => $type,
    size    => 0 + $r->{size},
    expires => $r->{expires},
  };
}

# Resolve a blobId argument that may be a creation-id reference ("#cid").
sub _blob_ref {
  my ($Self, $id) = @_;
  return undef unless defined $id;
  my $real = $Self->idmap($id);
  return undef if $real =~ /^#/;   # unresolved reference
  return $real;
}

# Order a create map so that every "#cid" reference to another entry in the
# same call is created first. $refs->($object) lists the ids an entry refers
# to. Returns (\@ordered, \@cyclic).
sub _blob_dependency_order {
  my ($create, $refs) = @_;
  my %pending = map { $_ => 1 } keys %$create;
  my (@order, %done);
  while (%pending) {
    my $progress = 0;
    for my $cid (sort keys %pending) {
      my @need = grep { defined && /^#(.+)/ && exists $create->{$1} && !$done{$1} }
                 $refs->($create->{$cid});
      next if grep { ($_ =~ /^#(.+)/)[0] ne $cid } @need;   # waits on another
      push @order, $cid;
      $done{$cid} = 1;
      delete $pending{$cid};
      $progress = 1;
    }
    last unless $progress;
  }
  return (\@order, [ sort keys %pending ]);
}

# Concatenate DataSourceObjects (RFC 9404 Section 4.1, blobext Section 3).
# Returns ($octets) or dies with a SetError hashref.
sub _blob_assemble {
  my ($Self, $sources, $strict_blob2) = @_;
  die { type => 'invalidProperties', properties => ['data'],
        description => 'data must be an array of DataSourceObjects' }
    unless ref $sources eq 'ARRAY';
  die { type => 'tooLarge', description => "more than $JMAP::BlobConvert::MAX_DATA_SOURCES data sources" }
    if @$sources > $JMAP::BlobConvert::MAX_DATA_SOURCES;

  my $out = '';
  my $i = 0;
  for my $src (@$sources) {
    my $path = "data/$i"; $i++;
    die { type => 'invalidProperties', properties => [$path] } unless ref $src eq 'HASH';
    my @kinds = grep { exists $src->{$_} && defined $src->{$_} } qw(data:asText data:asBase64 blobId);
    die { type => 'invalidProperties', properties => [$path],
          description => 'exactly one of data:asText, data:asBase64 or blobId is required' }
      unless @kinds == 1;

    my $octets;
    if ($kinds[0] eq 'data:asText') {
      my $text = $src->{'data:asText'};
      die { type => 'invalidProperties', properties => ["$path/data:asText"] } if ref $text;
      $octets = Encode::encode('UTF-8', $text);
      die { type => 'invalidProperties', properties => ["$path/data:asText"],
            description => 'data:asText is not valid UTF-8' }
        unless defined JMAP::BlobConvert::utf8_text($octets);
      for my $k (qw(offset length)) {
        die { type => 'invalidProperties', properties => ["$path/$k"],
              description => "$k applies to a blobId source" } if defined $src->{$k};
      }
    }
    elsif ($kinds[0] eq 'data:asBase64') {
      die { type => 'invalidProperties', properties => ["$path/data:asBase64"] } if ref $src->{'data:asBase64'};
      $octets = JMAP::BlobConvert::base64_octets($src->{'data:asBase64'});
      die { type => 'invalidProperties', properties => ["$path/data:asBase64"],
            description => 'data:asBase64 is not valid base64' } unless defined $octets;
      for my $k (qw(offset length)) {
        die { type => 'invalidProperties', properties => ["$path/$k"],
              description => "$k applies to a blobId source" } if defined $src->{$k};
      }
    }
    else {
      my $id = $Self->_blob_ref($src->{blobId});
      my ($type, $content) = defined $id ? $Self->_blob_fetch($id) : ();
      die { type => 'blobNotFound', notFound => [ $src->{blobId} ],
            description => "blob $src->{blobId} not found" } unless defined $content;
      my $offset = $src->{offset} // 0;
      my $length = $src->{length};
      for my $k (qw(offset length)) {
        die { type => 'invalidProperties', properties => ["$path/$k"] }
          if defined $src->{$k} && (ref $src->{$k} || $src->{$k} !~ /^\d+$/);
      }
      die { type => 'invalidProperties', properties => ["$path/offset"],
            description => 'offset is past the end of the blob' }
        if $offset > length $content;
      $length //= length($content) - $offset;
      die { type => 'invalidProperties', properties => ["$path/length"],
            description => 'the range extends past the end of the blob' }
        if $offset + $length > length $content;
      $octets = substr($content, $offset, $length);
      # blobext Section 3: size, position and digest:* given on a source MUST
      # match the data, or the object is rejected.
      if ($strict_blob2) {
        die { type => 'invalidProperties', properties => ["$path/size"],
              description => 'size does not match the source blob' }
          if defined $src->{size} && $src->{size} != length $content;
        die { type => 'invalidProperties', properties => ["$path/position"],
              description => 'position does not match the octets before this source' }
          if defined $src->{position} && $src->{position} != length $out;
        for my $k (grep { /^digest:(.+)/ } keys %$src) {
          my ($alg) = $k =~ /^digest:(.+)/;
          my $want = JMAP::BlobConvert::digest($alg, $octets);
          die { type => 'invalidProperties', properties => ["$path/$k"],
                description => defined $want ? "$k does not match the data" : "digest algorithm $alg is not supported" }
            unless defined $want && $want eq ($src->{$k} // '');
        }
      }
    }
    $out .= $octets;
    die { type => 'tooLarge', description => 'the blob would exceed maxSizeBlobSet' }
      if length($out) > $JMAP::BlobConvert::MAX_SIZE_BLOB_SET;
  }
  return $out;
}

# Create every entry of a Blob/upload or Blob/set create map.
sub _blob_create_all {
  my ($Self, $accountid, $create, $strict_blob2) = @_;
  my (%created, %notCreated);
  my ($order, $cyclic) = _blob_dependency_order($create, sub {
    my $o = shift;
    return () unless ref $o eq 'HASH' && ref $o->{data} eq 'ARRAY';
    return map { ref $_ eq 'HASH' ? $_->{blobId} : () } @{ $o->{data} };
  });
  $notCreated{$_} = { type => 'invalidProperties', properties => ['data'],
                      description => 'creation ids reference each other in a cycle' } for @$cyclic;
  for my $cid (@$order) {
    my $obj = $create->{$cid};
    unless (ref $obj eq 'HASH') {
      $notCreated{$cid} = { type => 'invalidProperties', properties => [] };
      next;
    }
    my @unknown = grep { !/^(data|type|noPersist)$/ } keys %$obj;
    if (@unknown) {
      $notCreated{$cid} = { type => 'invalidProperties', properties => [ sort @unknown ] };
      next;
    }
    if (defined $obj->{type} && ref $obj->{type}) {
      $notCreated{$cid} = { type => 'invalidProperties', properties => ['type'] };
      next;
    }
    my $octets = eval { $Self->_blob_assemble($obj->{data}, $strict_blob2) };
    if (my $err = $@) {
      $notCreated{$cid} = ref $err eq 'HASH' ? $err : { type => 'serverFail', description => "$err" };
      next;
    }
    my $blob = $Self->_blob_store($accountid, $obj->{type}, $octets, $obj->{noPersist});
    $Self->{idmap}{"#$cid"} = $blob->{id};   # RFC 9404 Section 4.1: always in createdIds
    $created{$cid} = $blob;
  }
  return (\%created, \%notCreated);
}

# ── Blob/upload (RFC 9404 Section 4.1) ──────────────────────────────────────

sub api_Blob_upload {
  my ($Self, $args) = @_;
  my ($accountid) = $Self->_blob_init($args);
  return ['error', { type => 'accountNotFound' }] unless defined $accountid;

  my ($created, $notCreated) = $Self->_blob_create_all($accountid, $args->{create} // {}, 0);
  # RFC 9404: created objects carry what the upload endpoint would return.
  return ['Blob/upload', {
    accountId  => $accountid,
    created    => _nullempty($created),
    notCreated => _nullempty($notCreated),
  }];
}

# ── Blob/set (blobext Section 4) ────────────────────────────────────────────

sub api_Blob_set {
  my ($Self, $args) = @_;
  my ($accountid) = $Self->_blob_init($args);
  return ['error', { type => 'accountNotFound' }] unless defined $accountid;
  return ['error', { type => 'stateMismatch' }] if defined $args->{ifInState};

  my ($created, $notCreated) = $Self->_blob_create_all($accountid, $args->{create} // {}, 1);

  my (%updated, %notUpdated, @destroyed, %notDestroyed);
  my $update = $args->{update} // {};
  for my $id (sort keys %$update) {
    my $patch = $update->{$id};
    unless (ref $patch eq 'HASH') {
      $notUpdated{$id} = { type => 'invalidPatch' };
      next;
    }
    my $real = $Self->_blob_ref($id);
    my ($type, $content) = defined $real ? $Self->_blob_fetch($real) : ();
    unless (defined $content) {
      $notUpdated{$id} = { type => 'notFound' };
      next;
    }
    # Only expires may change; anything else must equal the current value.
    my @bad;
    for my $k (sort keys %$patch) {
      next if $k eq 'expires';
      if    ($k eq 'id')   { push @bad, $k unless ($patch->{$k} // '') eq $id }
      elsif ($k eq 'size') { push @bad, $k unless ($patch->{$k} // -1) == length $content }
      elsif ($k eq 'type') { push @bad, $k unless ($patch->{$k} // '') eq ($type // '') }
      else                 { push @bad, $k }
    }
    if (@bad) {
      $notUpdated{$id} = { type => 'invalidProperties', properties => \@bad };
      next;
    }
    if ($real =~ /^f-(\d+)$/) {
      my $expires = time() + $BLOB_LIFETIME;
      $Self->begin();
      $Self->{db}->dbh->do('UPDATE jfiles SET expires = ?, mtime = ? WHERE jfileid = ?', {}, $expires, time(), $1);
      $Self->commit();
      $updated{$id} = { expires => Data::JSEmail::isodate($expires) };
    }
    else {
      # A message blob lives as long as its message; it has no expiry to touch.
      $updated{$id} = { expires => undef };
    }
  }

  for my $id (@{ $args->{destroy} // [] }) {
    my $real = $Self->_blob_ref($id);
    unless (defined $real) { $notDestroyed{$id} = { type => 'notFound' }; next }
    if ($real =~ /^m-/) {
      my ($type, $content) = $Self->_blob_fetch($real);
      $notDestroyed{$id} = defined $content
        ? { type => 'blobHasReference', description => 'the blob is part of an Email' }
        : { type => 'notFound' };
      next;
    }
    if ($real =~ /^f-(\d+)$/) {
      my $fileid = $1;
      $Self->begin();
      my $row = $Self->{db}->dgetone('jfiles', { jfileid => $fileid });
      if ($row) {
        $Self->{db}->dbh->do('DELETE FROM jfiles WHERE jfileid = ?', {}, $fileid);
      }
      $Self->commit();
      unless ($row) { $notDestroyed{$id} = { type => 'notFound' }; next }
      $Self->{db}->unlink_subdir('files', $fileid) if $Self->{db}->can('unlink_subdir');
      push @destroyed, $id;
      next;
    }
    $notDestroyed{$id} = { type => 'notFound' };
  }

  return ['Blob/set', {
    accountId    => $accountid,
    oldState     => undef,
    newState     => undef,
    created      => _nullempty($created),
    notCreated   => _nullempty($notCreated),
    updated      => _nullempty(\%updated),
    notUpdated   => _nullempty(\%notUpdated),
    destroyed    => _nullempty(\@destroyed),
    notDestroyed => _nullempty(\%notDestroyed),
  }];
}

# ── Blob/get (RFC 9404 Section 4.2, blobext Section 5) ──────────────────────

sub api_Blob_get {
  my ($Self, $args) = @_;
  my ($accountid) = $Self->_blob_init($args);
  return ['error', { type => 'accountNotFound' }] unless defined $accountid;
  my $blob2 = $Self->_blob_using($BLOB2);

  my @props = @{ $args->{properties} // ['data', 'size'] };
  my (@bad, %want);
  for my $p (@props) {
    if ($p =~ /^(data|data:asText|data:asBase64|size)$/) { $want{$p} = 1 }
    elsif ($p =~ /^digest:(.+)$/ && $DIGEST_OK{$1})     { $want{$p} = 1 }
    elsif ($blob2 && $p =~ /^(chunks|imageData)$/)        { $want{$p} = 1 }
    else { push @bad, $p }
  }
  return ['error', { type => 'invalidArguments', arguments => ['properties'],
                     description => 'unknown properties: ' . join(', ', @bad) }] if @bad;

  my $offset = $args->{offset} // 0;
  my $length = $args->{length};
  my @ds_props = @{ $args->{dataSourceProperties} // ['blobId', 'size'] };
  for my $p (@ds_props) {
    next if $p =~ /^(blobId|size|offset|length|position)$/;
    next if $p =~ /^digest:(.+)$/ && $DIGEST_OK{$1};
    return ['error', { type => 'invalidArguments', arguments => ['dataSourceProperties'],
                       description => "unknown data source property $p" }];
  }

  my (@list, @notFound);
  for my $id (@{ $args->{ids} }) {
    my $real = $Self->_blob_ref($id);
    my ($type, $content) = defined $real ? $Self->_blob_fetch($real) : ();
    unless (defined $content) { push @notFound, $id; next }

    my $size = length $content;
    my $truncated = 0;
    my $selected;
    if ($offset >= $size) {
      $selected = '';
      $truncated = 1 if $offset > $size || (defined $length && $length > 0);
    }
    else {
      my $avail = $size - $offset;
      my $take = defined $length && $length < $avail ? $length : $avail;
      $truncated = 1 if defined $length && $length > $avail;
      $selected = substr($content, $offset, $take);
    }

    my %obj = (id => $id, isEncodingProblem => $JSON::false, isTruncated => $truncated ? $JSON::true : $JSON::false);
    $obj{size} = $size if $want{size};
    if ($want{data} || $want{'data:asText'}) {
      my $text = JMAP::BlobConvert::utf8_text($selected);
      if (defined $text) {
        $obj{'data:asText'} = $text;
      }
      else {
        $obj{isEncodingProblem} = $JSON::true;
        $obj{'data:asText'} = undef if $want{'data:asText'};
        $obj{'data:asBase64'} = MIME::Base64::encode_base64($selected, '') if $want{data};
      }
    }
    $obj{'data:asBase64'} = MIME::Base64::encode_base64($selected, '') if $want{'data:asBase64'};
    for my $p (grep { /^digest:/ } keys %want) {
      my ($alg) = $p =~ /^digest:(.+)/;
      $obj{$p} = JMAP::BlobConvert::digest($alg, $selected);
    }
    if ($want{chunks}) {
      # Stored whole, so the blob is its own single chunk.
      my %chunk = (blobId => $id, size => $size, offset => 0, length => $size, position => 0);
      for my $p (grep { /^digest:/ } @ds_props) {
        my ($alg) = $p =~ /^digest:(.+)/;
        $chunk{$p} = JMAP::BlobConvert::digest($alg, $content);
      }
      $obj{chunks} = [ { map { $_ => $chunk{$_} } grep { exists $chunk{$_} } @ds_props } ];
    }
    if ($want{imageData}) {
      $obj{imageData} = JMAP::BlobConvert::image_data($content, $type);
    }
    push @list, \%obj;
  }

  return ['Blob/get', {
    accountId => $accountid,
    list      => \@list,
    notFound  => \@notFound,
  }];
}

# ── Blob/lookup (RFC 9404 Section 4.3, blobext Section 6) ───────────────────

sub api_Blob_lookup {
  my ($Self, $args) = @_;
  my ($accountid) = $Self->_blob_init($args);
  return ['error', { type => 'accountNotFound' }] unless defined $accountid;

  my @types = @{ $args->{typeNames} };
  for my $t (@types) {
    my $cap = $LOOKUP_TYPES{$t};
    return ['error', { type => 'unknownDataType', description => "$t is not a supported type name" }]
      unless $cap;
    return ['error', { type => 'unknownDataType',
                       description => "$t requires capability $cap in \"using\"" }]
      unless $Self->_blob_using($cap);
  }

  my @list;
  for my $id (@{ $args->{ids} }) {
    my %matched = map { $_ => [] } @types;
    my $real = $Self->_blob_ref($id) // '';
    if (my ($msgid) = $real =~ /^m-([^-]+)/) {
      $Self->begin();
      my $msg = $Self->{db}->dgetone('jmessages', { msgid => $msgid, active => 1 }, 'msgid,thrid');
      my @mboxes = $msg
        ? map { $_->{jmailboxid} } @{ $Self->{db}->dget('jmessagemap', { msgid => $msgid, active => 1 }, 'jmailboxid') }
        : ();
      $Self->commit();
      if ($msg) {
        $matched{Email}   = [ "$msgid" ]        if exists $matched{Email};
        $matched{Thread}  = [ "$msg->{thrid}" ] if exists $matched{Thread} && defined $msg->{thrid};
        $matched{Mailbox} = [ map { "$_" } sort @mboxes ] if exists $matched{Mailbox};
      }
    }
    # An unknown or invisible blob gets empty lists, never a hint it exists.
    push @list, { id => $id, matchedIds => \%matched };
  }

  return ['Blob/lookup', { accountId => $accountid, list => \@list }];
}

# ── Blob/convert (blobext Section 8) ────────────────────────────────────────

my %RECIPES = map { $_ => 1 } qw(imageConvert archive extract compress decompress delta patch);

# Every blobId a conversion request refers to (for dependency ordering).
sub _convert_refs {
  my ($o) = @_;
  return () unless ref $o eq 'HASH';
  my @ids;
  for my $r (grep { $RECIPES{$_} } keys %$o) {
    my $recipe = $o->{$r};
    next unless ref $recipe eq 'HASH';
    push @ids, @{$recipe}{qw(blobId newBlobId deltaBlobId)};
    push @ids, map { ref $_ eq 'HASH' ? $_->{blobId} : () } @{ $recipe->{entries} }
      if ref $recipe->{entries} eq 'ARRAY';
  }
  return grep { defined } @ids;
}

sub _convert_source {
  my ($Self, $recipe, $key) = @_;
  my $ref = $recipe->{$key};
  die { type => 'invalidProperties', properties => [$key] } unless defined $ref && !ref $ref;
  my $id = $Self->_blob_ref($ref);
  my ($type, $content) = defined $id ? $Self->_blob_fetch($id) : ();
  die { type => 'notFound', description => "blob $ref not found" } unless defined $content;
  die { type => 'tooLarge', description => "$key exceeds maxConvertSize" }
    if length($content) > $JMAP::BlobConvert::MAX_CONVERT_SIZE;
  return ($id, $type, $content);
}

sub _convert_one {
  my ($Self, $accountid, $obj) = @_;
  my @kinds = grep { $RECIPES{$_} } keys %$obj;
  die { type => 'invalidProperties', properties => [ sort grep { !$RECIPES{$_} && $_ ne 'noPersist' } keys %$obj ],
        description => 'exactly one recipe is required' } unless @kinds == 1;
  my @unknown = grep { !$RECIPES{$_} && $_ ne 'noPersist' } keys %$obj;
  die { type => 'invalidProperties', properties => [ sort @unknown ] } if @unknown;
  my $kind = $kinds[0];
  my $recipe = $obj->{$kind};
  die { type => 'invalidProperties', properties => [$kind] } unless ref $recipe eq 'HASH';

  my ($octets, $type, %extra);
  if ($kind eq 'compress') {
    my (undef, undef, $in) = $Self->_convert_source($recipe, 'blobId');
    die { type => 'invalidProperties', properties => ['compress/type'] } unless defined $recipe->{type};
    $octets = JMAP::BlobConvert::compress($in, $recipe->{type}, $recipe->{level}, $recipe->{checksum});
    $type = $recipe->{type};
  }
  elsif ($kind eq 'decompress') {
    my (undef, undef, $in) = $Self->_convert_source($recipe, 'blobId');
    my $r = JMAP::BlobConvert::decompress($in, $recipe->{type});
    $octets = $r->{content};
    $type = JMAP::BlobConvert::detect_type($octets) // 'application/octet-stream';
    @extra{qw(isIncomplete description)} = ($JSON::true, $r->{description}) if $r->{isIncomplete};
  }
  elsif ($kind eq 'archive') {
    die { type => 'invalidProperties', properties => ['archive/type'] } unless defined $recipe->{type};
    die { type => 'invalidProperties', properties => ['archive/entries'] } unless ref $recipe->{entries} eq 'ARRAY';
    my @entries;
    my $i = 0;
    for my $e (@{ $recipe->{entries} }) {
      my $path = "archive/entries/" . $i++;
      die { type => 'invalidProperties', properties => [$path] } unless ref $e eq 'HASH';
      my %entry = %$e;
      if (defined $e->{blobId}) {
        my (undef, undef, $content) = $Self->_convert_source($e, 'blobId');
        $entry{content} = $content;
      }
      push @entries, \%entry;
    }
    $octets = JMAP::BlobConvert::archive($recipe->{type}, \@entries);
    $type = $recipe->{type};
  }
  elsif ($kind eq 'extract') {
    my ($src_id, undef, $in) = $Self->_convert_source($recipe, 'blobId');
    my $r = JMAP::BlobConvert::extract($in, $recipe->{type});
    my @entries;
    for my $e (@{ $r->{entries} }) {
      my %out = %$e;
      my $content = delete $out{content};
      $out{blobId} = defined $content
        ? $Self->_blob_store($accountid, undef, $content, 0)->{id}
        : undef;
      push @entries, { map { $_ => $out{$_} } grep { defined $out{$_} || /^(blobId|linkTarget)$/ } keys %out };
    }
    # The extracted archive is what this creation describes: its own blobId,
    # type and size, plus the entries found inside it.
    @extra{qw(isIncomplete description)} = ($JSON::true, $r->{description}) if $r->{isIncomplete};
    return { id => $src_id, type => $r->{type}, size => length $in, entries => \@entries, %extra };
  }
  elsif ($kind eq 'delta') {
    my (undef, undef, $base) = $Self->_convert_source($recipe, 'blobId');
    my (undef, undef, $new)  = $Self->_convert_source($recipe, 'newBlobId');
    die { type => 'invalidProperties', properties => ['delta/type'] } unless defined $recipe->{type};
    $octets = JMAP::BlobConvert::delta($base, $new, $recipe->{type});
    $type = $recipe->{type};
  }
  elsif ($kind eq 'patch') {
    my (undef, $base_type, $base) = $Self->_convert_source($recipe, 'blobId');
    my (undef, undef, $delta)     = $Self->_convert_source($recipe, 'deltaBlobId');
    die { type => 'invalidProperties', properties => ['patch/deltaType'] } unless defined $recipe->{deltaType};
    $octets = JMAP::BlobConvert::patch($base, $delta, $recipe->{deltaType});
    $type = $base_type;
  }
  elsif ($kind eq 'imageConvert') {
    my (undef, undef, $in) = $Self->_convert_source($recipe, 'blobId');
    ($octets, $type) = JMAP::BlobConvert::image_convert($in, $recipe);
  }

  my $blob = $Self->_blob_store($accountid, $type, $octets, $obj->{noPersist});
  return { %$blob, %extra };
}

sub api_Blob_convert {
  my ($Self, $args) = @_;
  my ($accountid) = $Self->_blob_init($args);
  return ['error', { type => 'accountNotFound' }] unless defined $accountid;

  my $create = $args->{create} // {};
  my (%created, %notCreated);
  my ($order, $cyclic) = _blob_dependency_order($create, \&_convert_refs);
  # Section 8: every member of a dependency cycle is invalidProperties.
  $notCreated{$_} = { type => 'invalidProperties', properties => [],
                      description => 'creation ids reference each other in a cycle' } for @$cyclic;
  for my $cid (@$order) {
    my $obj = $create->{$cid};
    unless (ref $obj eq 'HASH') {
      $notCreated{$cid} = { type => 'invalidProperties', properties => [] };
      next;
    }
    my $result = eval { $Self->_convert_one($accountid, $obj) };
    if (my $err = $@) {
      $notCreated{$cid} = ref $err eq 'HASH' ? $err : { type => 'conversionFailed', description => "$err" };
      next;
    }
    $Self->{idmap}{"#$cid"} = $result->{id};
    $created{$cid} = $result;
  }

  return ['Blob/convert', {
    accountId  => $accountid,
    created    => _nullempty(\%created),
    notCreated => _nullempty(\%notCreated),
  }];
}

1;
