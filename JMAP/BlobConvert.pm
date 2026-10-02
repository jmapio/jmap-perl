#!/usr/bin/perl -cw

use strict;
use warnings;

# The pure part of the blob extensions: byte strings in, byte strings out.
#
# RFC 9404 (urn:ietf:params:jmap:blob) needs UTF-8 validation and digests;
# draft-ietf-jmap-blobext (urn:ietf:params:jmap:blob2) adds Blob/convert with
# archive, extract, compress, decompress, delta, patch and image recipes, plus
# the imageData property of Blob/get. Everything here is independent of the
# database and the JMAP layer so that t/blob-convert.t can exercise it alone;
# JMAP::API::Blob maps the results onto method responses.
#
# Which recipe types are supported depends on which optional modules load.
# capabilities() reports exactly that, so the session only ever advertises
# what the running proxy can do.
#
# Failures are raised as hashrefs shaped like a SetError:
#   die { type => 'unknownFormat', description => '...' }

package JMAP::BlobConvert;

use Encode ();
use MIME::Base64 ();
use Digest::SHA ();
use Digest::MD5 ();
use Archive::Tar ();
use Archive::Tar::Constant ();
use IO::Compress::Zip ();
use IO::Uncompress::Unzip ();
use IO::Compress::Gzip ();
use IO::Uncompress::Gunzip ();
use IO::Compress::Bzip2 ();
use IO::Uncompress::Bunzip2 ();
use Text::Diff ();
use Image::Size ();
use POSIX ();

our %HAVE;
BEGIN {
  for my $m (qw(IO::Compress::Xz IO::Uncompress::UnXz IO::Compress::Zstd
                IO::Uncompress::UnZstd Imager Image::ExifTool)) {
    $HAVE{$m} = eval "require $m; 1" ? 1 : 0;
  }
}

our $MAX_SIZE_BLOB_SET   = 50_000_000;
our $MAX_DATA_SOURCES    = 64;
our $MAX_CONVERT_SIZE    = 50_000_000;
our $MAX_ARCHIVE_ENTRIES = 10_000;
our $MAX_IMAGE_DIMENSION = 8192;
our @DIGEST_ALGORITHMS   = qw(sha-256 sha sha-512 md5);

my %IMAGER_TYPE = (
  'image/png'  => 'png',  'image/jpeg' => 'jpeg', 'image/gif'  => 'gif',
  'image/webp' => 'webp', 'image/tiff' => 'tiff', 'image/bmp'  => 'bmp',
);
my %IMAGER_HAS_ALPHA = map { $_ => 1 } qw(image/png image/gif image/webp image/tiff);

sub _fail {
  my ($type, $description) = @_;
  die { type => $type, ($description ? (description => $description) : ()) };
}

# ── capability advertisement ────────────────────────────────────────────────

sub compress_types {
  my @t = ('application/gzip', 'application/x-bzip2');
  push @t, 'application/x-xz'  if $HAVE{'IO::Compress::Xz'} && $HAVE{'IO::Uncompress::UnXz'};
  push @t, 'application/zstd'  if $HAVE{'IO::Compress::Zstd'} && $HAVE{'IO::Uncompress::UnZstd'};
  return @t;
}

sub archive_types { return ('application/zip', 'application/x-tar') }

sub image_read_types {
  return () unless $HAVE{Imager};
  my %can = map { $_ => 1 } Imager->read_types;
  return sort grep { $can{ $IMAGER_TYPE{$_} } } keys %IMAGER_TYPE;
}

sub image_write_types {
  return () unless $HAVE{Imager};
  my %can = map { $_ => 1 } Imager->write_types;
  return sort grep { $can{ $IMAGER_TYPE{$_} } } keys %IMAGER_TYPE;
}

sub delta_types { return ('text/x-diff') }

# The blob2-specific slice of the accountCapabilities object
# (draft-ietf-jmap-blobext Section 2.1). null means "not supported".
sub capabilities {
  my @img_r = image_read_types();
  my @img_w = image_write_types();
  return {
    supportedImageReadTypes  => @img_r && @img_w ? [@img_r] : undef,
    supportedImageWriteTypes => @img_r && @img_w ? [@img_w] : undef,
    supportedArchiveTypes    => [ archive_types() ],
    supportedExtractTypes    => [ archive_types() ],
    supportedCompressTypes   => [ compress_types() ],
    supportedDecompressTypes => [ compress_types() ],
    supportedDeltaTypes      => [ delta_types() ],
    supportedPatchTypes      => [ delta_types() ],
    maxConvertSize           => $MAX_CONVERT_SIZE,
    maxArchiveEntries        => $MAX_ARCHIVE_ENTRIES,
    maxImageDimension        => @img_r && @img_w ? $MAX_IMAGE_DIMENSION : undef,
  };
}

# ── octet utilities ─────────────────────────────────────────────────────────

# Strict UTF-8 check (RFC 9404 Section 4.2): returns the decoded character
# string, or undef when the octets are not valid UTF-8, including a sequence
# cut in the middle of a multi-octet character.
sub utf8_text {
  my ($bytes) = @_;
  return '' unless length $bytes;
  my $text = eval { Encode::decode('UTF-8', $bytes, Encode::FB_CROAK | Encode::LEAVE_SRC) };
  return $@ ? undef : $text;
}

# Base64 digest of $bytes with an algorithm named as in the HTTP Digest
# Algorithm Values registry, lowercased. undef for an algorithm we lack.
sub digest {
  my ($algorithm, $bytes) = @_;
  my $raw = $algorithm eq 'sha-256' ? Digest::SHA::sha256($bytes)
          : $algorithm eq 'sha-512' ? Digest::SHA::sha512($bytes)
          : $algorithm eq 'sha'     ? Digest::SHA::sha1($bytes)
          : $algorithm eq 'md5'     ? Digest::MD5::md5($bytes)
          : return undef;
  return MIME::Base64::encode_base64($raw, '');
}

# Strict base64 decode: the alphabet and padding must be right, or undef.
sub base64_octets {
  my ($b64) = @_;
  (my $clean = $b64) =~ s/\s+//g;
  return undef if $clean =~ m{[^A-Za-z0-9+/=]};
  return undef if length($clean) % 4;
  return undef if $clean =~ /=/ && $clean !~ /^[A-Za-z0-9+\/]*={0,2}$/;
  return MIME::Base64::decode_base64($clean);
}

# Media type from magic numbers, for recipes whose "type" is null and for the
# type of an upload that gave no hint. undef when nothing is recognised.
sub detect_type {
  my ($bytes) = @_;
  return undef unless defined $bytes && length $bytes;
  return 'application/zip'     if $bytes =~ /^PK\x03\x04/ || $bytes =~ /^PK\x05\x06/;
  return 'application/gzip'    if $bytes =~ /^\x1f\x8b/;
  return 'application/x-bzip2' if $bytes =~ /^BZh[1-9]/;
  return 'application/x-xz'    if $bytes =~ /^\xfd7zXZ\x00/;
  return 'application/zstd'    if $bytes =~ /^\x28\xb5\x2f\xfd/;
  return 'application/x-tar'   if length($bytes) >= 262 && substr($bytes, 257, 5) eq 'ustar';
  return 'image/png'           if $bytes =~ /^\x89PNG\r\n\x1a\n/;
  return 'image/jpeg'          if $bytes =~ /^\xff\xd8\xff/;
  return 'image/gif'           if $bytes =~ /^GIF8[79]a/;
  return 'image/webp'          if $bytes =~ /^RIFF....WEBP/s;
  return 'image/tiff'          if $bytes =~ /^(II\x2a\x00|MM\x00\x2a)/;
  return 'image/bmp'           if $bytes =~ /^BM/;
  return undef;
}

sub _iso8601 {
  my ($epoch) = @_;
  return POSIX::strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($epoch));
}

sub _epoch {
  my ($utcdate) = @_;
  return time() unless defined $utcdate;
  my ($y, $mo, $d, $h, $mi, $s) = $utcdate =~ /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)/
    or _fail('invalidProperties', "modified is not a UTCDate: $utcdate");
  require Time::Local;
  return Time::Local::timegm($s, $mi, $h, $d, $mo - 1, $y);
}

# ── archives (Section 8.2 - 8.4) ────────────────────────────────────────────

my %TAR_TYPE = (
  file        => Archive::Tar::Constant::FILE(),
  directory   => Archive::Tar::Constant::DIR(),
  symlink     => Archive::Tar::Constant::SYMLINK(),
  hardlink    => Archive::Tar::Constant::HARDLINK(),
  fifo        => Archive::Tar::Constant::FIFO(),
  blockDevice => Archive::Tar::Constant::BLOCKDEV(),
  charDevice  => Archive::Tar::Constant::CHARDEV(),
);
my %TAR_NAME = reverse %TAR_TYPE;

# Validate one ArchiveEntry (Section 8.3) against the archive format. The
# caller has already resolved blobId to {content}. Returns the entryType.
sub _check_entry {
  my ($type, $entry, $path) = @_;
  _fail('invalidProperties', "$path/name is required")
    unless defined $entry->{name} && length $entry->{name};
  my $et = $entry->{entryType} // 'file';
  _fail('invalidProperties', "$path/entryType $et is not defined")
    unless exists $TAR_TYPE{$et};
  if ($type eq 'application/zip') {
    _fail('invalidProperties', "$path/entryType $et is not supported in application/zip")
      unless $et eq 'file' || $et eq 'directory';
  }
  if ($et eq 'file') {
    _fail('invalidProperties', "$path/blobId is required for a file entry")
      unless defined $entry->{content};
  }
  else {
    _fail('invalidProperties', "$path/blobId must be null for a $et entry")
      if defined $entry->{blobId};
  }
  if ($et eq 'symlink' || $et eq 'hardlink') {
    _fail('invalidProperties', "$path/linkTarget is required for a $et entry")
      unless defined $entry->{linkTarget} && length $entry->{linkTarget};
  }
  elsif (defined $entry->{linkTarget}) {
    _fail('invalidProperties', "$path/linkTarget must be null for a $et entry");
  }
  _fail('invalidProperties', "$path/name of a directory must end with /")
    if $et eq 'directory' && $entry->{name} !~ m{/$};
  if (defined $entry->{mode}) {
    _fail('invalidProperties', "$path/mode must be an octal string")
      unless $entry->{mode} =~ /^0?[0-7]{3,4}$/;
  }
  if (defined $entry->{compressionMethod}) {
    _fail('invalidProperties', "$path/compressionMethod must be store or deflate")
      unless $entry->{compressionMethod} =~ /^(store|deflate)$/;
  }
  return $et;
}

# entries: [ { name, content, entryType, modified, linkTarget, mode, uid, gid,
#              ownerName, groupName, devMajor, devMinor, comment,
#              compressionMethod } ]  -- content holds the entry's octets.
sub archive {
  my ($type, $entries) = @_;
  _fail('invalidProperties', "type $type is not a supported archive type")
    unless grep { $_ eq $type } archive_types();
  _fail('tooLarge', 'too many entries') if @$entries > $MAX_ARCHIVE_ENTRIES;

  my $i = 0;
  my @checked = map { [ _check_entry($type, $_, "entries/" . $i++), $_ ] } @$entries;

  if ($type eq 'application/x-tar') {
    my $tar = Archive::Tar->new;
    for my $c (@checked) {
      my ($et, $e) = @$c;
      my %opt = (
        type  => $TAR_TYPE{$et},
        mode  => oct($e->{mode} // ($et eq 'directory' ? '0755' : '0644')),
        mtime => _epoch($e->{modified}),
        uid   => $e->{uid} // 0,
        gid   => $e->{gid} // 0,
        uname => $e->{ownerName} // '',
        gname => $e->{groupName} // '',
      );
      $opt{linkname} = $e->{linkTarget} if defined $e->{linkTarget};
      $opt{devmajor} = $e->{devMajor} // 0 if $et =~ /Device$/;
      $opt{devminor} = $e->{devMinor} // 0 if $et =~ /Device$/;
      $tar->add_data($e->{name}, $et eq 'file' ? $e->{content} : '', \%opt)
        or _fail('conversionFailed', "tar: " . ($tar->error // 'add_data failed'));
    }
    my $out = $tar->write;
    _fail('conversionFailed', "tar: " . ($tar->error // 'write failed')) unless defined $out;
    return $out;
  }

  # application/zip
  return "PK\x05\x06" . ("\x00" x 18) unless @checked;   # the empty archive
  my $out = '';
  my $zip;
  for my $c (@checked) {
    my ($et, $e) = @$c;
    my %opt = (
      Name  => $e->{name},
      Time  => _epoch($e->{modified}),
      Method => ($e->{compressionMethod} // 'deflate') eq 'store'
                ? IO::Compress::Zip::ZIP_CM_STORE() : IO::Compress::Zip::ZIP_CM_DEFLATE(),
      (defined $e->{comment} ? (Comment => $e->{comment}) : ()),
    );
    if ($zip) { $zip->newStream(%opt) or _fail('conversionFailed', "zip: $IO::Compress::Zip::ZipError") }
    else {
      $zip = IO::Compress::Zip->new(\$out, %opt)
        or _fail('conversionFailed', "zip: $IO::Compress::Zip::ZipError");
    }
    $zip->print($e->{content}) if $et eq 'file';
  }
  $zip->close or _fail('conversionFailed', "zip: $IO::Compress::Zip::ZipError");
  return $out;
}

# Returns { type, entries => [ { name, content, entryType, modified, ... } ],
#           isIncomplete, description }
sub extract {
  my ($bytes, $type) = @_;
  _fail('tooLarge', 'archive exceeds maxConvertSize') if length($bytes) > $MAX_CONVERT_SIZE;
  $type //= detect_type($bytes)
    // _fail('unknownFormat', 'could not detect the archive format');
  _fail('invalidProperties', "type $type is not a supported archive type")
    unless grep { $_ eq $type } archive_types();

  my (@entries, $incomplete, $why);
  if ($type eq 'application/x-tar') {
    open my $fh, '<', \$bytes or _fail('conversionFailed', "tar: $!");
    binmode $fh;
    my $tar = Archive::Tar->new;
    my @files = $tar->read($fh);
    my $err = $tar->error;
    _fail('unknownFormat', "tar: $err") if !@files && $err;
    _fail('unknownFormat', 'not a tar archive') if !@files && length $bytes;
    if ($err) { $incomplete = 1; $why = "tar: $err" }
    for my $f (@files) {
      my $et = $TAR_NAME{ $f->type } // 'file';
      my $name = $f->full_path;
      $name .= '/' if $et eq 'directory' && $name !~ m{/$};
      push @entries, {
        name      => $name,
        entryType => $et,
        content   => $et eq 'file' ? $f->get_content : undef,
        modified  => _iso8601($f->mtime),
        mode      => sprintf('%04o', $f->mode),
        uid       => $f->uid, gid => $f->gid,
        ownerName => (length($f->uname // '') ? $f->uname : undef),
        groupName => (length($f->gname // '') ? $f->gname : undef),
        linkTarget => ($et eq 'symlink' || $et eq 'hardlink') ? $f->linkname : undef,
        ($et =~ /Device$/ ? (devMajor => $f->devmajor, devMinor => $f->devminor) : ()),
      };
    }
  }
  elsif ($bytes =~ /^PK\x05\x06/) {
    # an end-of-central-directory record alone: the empty archive
  }
  else {
    my $u = IO::Uncompress::Unzip->new(\$bytes)
      or _fail('unknownFormat', "zip: $IO::Uncompress::Unzip::UnzipError");
    my $status;
    do {
      my $h = $u->getHeaderInfo;
      my $content = '';
      my $n;
      while (($n = $u->read(my $buf)) > 0) { $content .= $buf }
      if ($n < 0) { $incomplete = 1; $why = "zip: $IO::Uncompress::Unzip::UnzipError" }
      my $is_dir = $h->{Name} =~ m{/$} && !length $content;
      push @entries, {
        name      => $h->{Name},
        entryType => $is_dir ? 'directory' : 'file',
        content   => $is_dir ? undef : $content,
        modified  => _iso8601($h->{Time} // time()),
        comment   => (defined $h->{Comment} && length $h->{Comment}) ? $h->{Comment} : undef,
        compressionMethod => ($h->{MethodID} // 8) == 0 ? 'store' : 'deflate',
      };
      $status = $u->nextStream;
    } while ($status == 1);
    if ($status < 0) { $incomplete = 1; $why //= "zip: $IO::Uncompress::Unzip::UnzipError" }
  }
  return { type => $type, entries => \@entries,
           isIncomplete => $incomplete ? 1 : 0, description => $why };
}

# ── compression (Section 8.5 - 8.6) ─────────────────────────────────────────

my %LEVEL_RANGE = (
  'application/gzip'    => [1, 9, 6],
  'application/x-bzip2' => [1, 9, 9],
  'application/x-xz'    => [0, 9, 6],
  'application/zstd'    => [1, 22, 3],
);

sub _clamp_level {
  my ($type, $level) = @_;
  my ($min, $max, $default) = @{ $LEVEL_RANGE{$type} };
  return $default unless defined $level;
  return $level < $min ? $min : $level > $max ? $max : $level;
}

sub compress {
  my ($bytes, $type, $level, $checksum) = @_;
  _fail('tooLarge', 'blob exceeds maxConvertSize') if length($bytes) > $MAX_CONVERT_SIZE;
  _fail('invalidProperties', "type $type is not a supported compression type")
    unless grep { $_ eq $type } compress_types();
  $level = _clamp_level($type, $level);
  my $out = '';
  my $ok;
  if ($type eq 'application/gzip') {
    $ok = IO::Compress::Gzip::gzip(\$bytes => \$out, -Level => $level, Minimal => 1)
      or _fail('conversionFailed', "gzip: $IO::Compress::Gzip::GzipError");
  }
  elsif ($type eq 'application/x-bzip2') {
    $ok = IO::Compress::Bzip2::bzip2(\$bytes => \$out, BlockSize100K => $level)
      or _fail('conversionFailed', "bzip2: $IO::Compress::Bzip2::Bzip2Error");
  }
  elsif ($type eq 'application/x-xz') {
    my %opt = (Preset => $level);
    if ($checksum) {
      my $sha = eval { Compress::Raw::Lzma::LZMA_CHECK_SHA256() };
      $opt{Check} = $sha if defined $sha;
    }
    $ok = IO::Compress::Xz::xz(\$bytes => \$out, %opt)
      or _fail('conversionFailed', "xz: " . eval { $IO::Compress::Xz::XzError });
  }
  elsif ($type eq 'application/zstd') {
    # IO::Compress::Zstd offers no frame-checksum switch; the format default
    # (no checksum) applies whatever "checksum" says.
    $ok = IO::Compress::Zstd::zstd(\$bytes => \$out, Level => $level)
      or _fail('conversionFailed', "zstd: " . eval { $IO::Compress::Zstd::ZstdError });
  }
  return $out;
}

# Returns { type, content, isIncomplete, description }
sub decompress {
  my ($bytes, $type) = @_;
  _fail('tooLarge', 'blob exceeds maxConvertSize') if length($bytes) > $MAX_CONVERT_SIZE;
  $type //= detect_type($bytes)
    // _fail('unknownFormat', 'could not detect the compression format');
  _fail('invalidProperties', "type $type is not a supported compression type")
    unless grep { $_ eq $type } compress_types();
  my $out = '';
  my ($ok, $err);
  if ($type eq 'application/gzip') {
    $ok = IO::Uncompress::Gunzip::gunzip(\$bytes => \$out, MultiStream => 1);
    $err = $IO::Uncompress::Gunzip::GunzipError;
  }
  elsif ($type eq 'application/x-bzip2') {
    $ok = IO::Uncompress::Bunzip2::bunzip2(\$bytes => \$out, MultiStream => 1);
    $err = $IO::Uncompress::Bunzip2::Bunzip2Error;
  }
  elsif ($type eq 'application/x-xz') {
    $ok = IO::Uncompress::UnXz::unxz(\$bytes => \$out, MultiStream => 1);
    $err = eval { $IO::Uncompress::UnXz::UnXzError };
  }
  elsif ($type eq 'application/zstd') {
    $ok = IO::Uncompress::UnZstd::unzstd(\$bytes => \$out, MultiStream => 1);
    $err = eval { $IO::Uncompress::UnZstd::UnZstdError };
  }
  unless ($ok) {
    _fail('unknownFormat', "$type: $err") unless length $out;
    return { type => $type, content => $out, isIncomplete => 1, description => "$type: $err" };
  }
  return { type => $type, content => $out, isIncomplete => 0 };
}

# ── deltas (Section 8.7 - 8.8) ──────────────────────────────────────────────

sub delta {
  my ($base, $new, $type) = @_;
  _fail('invalidProperties', "type $type is not a supported delta type")
    unless grep { $_ eq $type } delta_types();
  _fail('tooLarge', 'blob exceeds maxConvertSize')
    if length($base) > $MAX_CONVERT_SIZE || length($new) > $MAX_CONVERT_SIZE;
  my $a = utf8_text($base) // _fail('unknownFormat', 'the base blob is not text');
  my $b = utf8_text($new)  // _fail('unknownFormat', 'the new blob is not text');
  my $diff = Text::Diff::diff(\$a, \$b, {
    STYLE => 'Unified', FILENAME_A => 'a', FILENAME_B => 'b', CONTEXT => 3,
  });
  return Encode::encode('UTF-8', $diff);
}

sub _split_lines {
  my ($text) = @_;
  return () unless length $text;
  my @lines = split /(?<=\n)/, $text;
  return @lines;
}

# Apply a unified diff strictly: every context and removed line must match
# the base exactly, else the delta does not belong to this base.
sub patch {
  my ($base, $delta, $type) = @_;
  _fail('invalidProperties', "deltaType $type is not a supported patch type")
    unless grep { $_ eq $type } delta_types();
  _fail('tooLarge', 'blob exceeds maxConvertSize')
    if length($base) > $MAX_CONVERT_SIZE || length($delta) > $MAX_CONVERT_SIZE;
  my $text  = utf8_text($base)  // _fail('unknownFormat', 'the base blob is not text');
  my $dtext = utf8_text($delta) // _fail('unknownFormat', 'the delta is not text');

  my @old = _split_lines($text);
  my @dlines = _split_lines($dtext);
  my @new;
  my $pos = 0;          # next unconsumed line of @old
  my $saw_hunk = 0;

  my $i = 0;
  while ($i < @dlines) {
    my $l = $dlines[$i++];
    next if $l =~ /^(---|\+\+\+) /;
    next if $l =~ /^(diff |index |Only in )/;
    if ($l =~ /^\@\@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? \@\@/) {
      my ($ostart, $ocount) = ($1, $2 // 1);
      $saw_hunk = 1;
      my $target = $ocount == 0 ? $ostart : $ostart - 1;   # 0-based index into @old
      _fail('unknownFormat', 'hunk starts before the previous one ended') if $target < $pos;
      _fail('unknownFormat', 'hunk starts past the end of the base') if $target > @old;
      push @new, @old[$pos .. $target - 1];
      $pos = $target;
      my $consumed = 0;
      while ($i < @dlines && $consumed < $ocount || ($i < @dlines && $dlines[$i] =~ /^[+\\]/)) {
        my $d = $dlines[$i];
        last if $d =~ /^\@\@/;
        $i++;
        if ($d =~ /^\\ No newline at end of file/) {
          # the previous emitted/consumed line had no trailing newline
          if (@new && $new[-1] =~ /\n\z/ && $dlines[$i-2] =~ /^[ +]/) { $new[-1] =~ s/\n\z// }
          next;
        }
        my ($op, $body) = $d =~ /^([ +-])(.*\n?)\z/s
          or _fail('unknownFormat', "malformed delta line: $d");
        if ($op eq ' ' || $op eq '-') {
          _fail('unknownFormat', 'the delta does not apply to this base')
            unless $pos < @old && _same_line($old[$pos], $body);
          push @new, $old[$pos] if $op eq ' ';
          $pos++; $consumed++;
        }
        else { push @new, $body }
      }
    }
    elsif ($l =~ /\S/) {
      _fail('unknownFormat', "unrecognised delta line: $l");
    }
  }
  _fail('unknownFormat', 'the delta contains no hunks') unless $saw_hunk;
  push @new, @old[$pos .. $#old];
  return Encode::encode('UTF-8', join('', @new));
}

sub _same_line {
  my ($a, $b) = @_;
  (my $x = $a) =~ s/\n\z//;
  (my $y = $b) =~ s/\n\z//;
  return $x eq $y;
}

# ── images (Section 8.1 and the imageData property) ─────────────────────────

sub image_convert {
  my ($bytes, $recipe) = @_;
  _fail('invalidProperties', 'image conversion is not supported') unless $HAVE{Imager};
  _fail('tooLarge', 'blob exceeds maxConvertSize') if length($bytes) > $MAX_CONVERT_SIZE;
  my $type = $recipe->{type} // _fail('invalidProperties', 'type is required');
  _fail('invalidProperties', "type $type is not in supportedImageWriteTypes")
    unless grep { $_ eq $type } image_write_types();
  my $src_type = detect_type($bytes) // '';
  _fail('invalidProperties', "the source image type " . ($src_type || 'is unknown and') . " is not in supportedImageReadTypes")
    unless grep { $_ eq $src_type } image_read_types();
  for my $dim (qw(width height)) {
    next unless defined $recipe->{$dim};
    _fail('tooLarge', "$dim exceeds maxImageDimension") if $recipe->{$dim} > $MAX_IMAGE_DIMENSION;
    _fail('invalidProperties', "$dim must be positive") if $recipe->{$dim} < 1;
  }

  my $img = Imager->new;
  $img->read(data => $bytes, type => $IMAGER_TYPE{$src_type})
    or _fail('conversionFailed', 'could not read the image: ' . $img->errstr);

  if ($recipe->{autoOrient}) {
    my $o = $img->tags(name => 'exif_orientation') || 1;
    $img = $img->flip(dir => 'h')            if $o == 2;
    $img = $img->rotate(degrees => 180)      if $o == 3;
    $img = $img->flip(dir => 'v')            if $o == 4;
    $img = $img->flip(dir => 'h')->rotate(degrees => 90)  if $o == 5;
    $img = $img->rotate(degrees => 90)       if $o == 6;
    $img = $img->flip(dir => 'h')->rotate(degrees => 270) if $o == 7;
    $img = $img->rotate(degrees => 270)      if $o == 8;
    $img->settag(name => 'exif_orientation', value => 1) if $o != 1;
  }

  my ($w, $h) = ($img->getwidth, $img->getheight);
  my ($tw, $th) = ($recipe->{width}, $recipe->{height});
  if (defined $tw || defined $th) {
    if ($recipe->{ignoreAspect} && defined $tw && defined $th) {
      $img = $img->scale(xpixels => $tw, ypixels => $th, type => 'nonprop')
        or _fail('conversionFailed', 'scale failed: ' . Imager->errstr);
    }
    else {
      # "Maximum width/height": shrink to fit, never enlarge.
      my $fx = defined $tw && $w > $tw ? $tw / $w : 1;
      my $fy = defined $th && $h > $th ? $th / $h : 1;
      my $f = $fx < $fy ? $fx : $fy;
      if ($f < 1) {
        $img = $img->scale(scalefactor => $f)
          or _fail('conversionFailed', 'scale failed: ' . Imager->errstr);
      }
    }
  }

  if (($recipe->{colorSpace} // '') eq 'grayscale') {
    $img = $img->convert(preset => 'grey') or _fail('conversionFailed', 'convert failed');
  }
  elsif (defined $recipe->{colorSpace} && $recipe->{colorSpace} ne 'sRGB') {
    _fail('invalidProperties', "colorSpace $recipe->{colorSpace} is not defined");
  }

  # Flatten transparency when the target cannot carry it.
  if (!$IMAGER_HAS_ALPHA{$type} && ($img->getchannels == 4 || $img->getchannels == 2)) {
    my $bg = $recipe->{background} // '#ffffff';
    _fail('invalidProperties', 'background must be a #rrggbb colour') unless $bg =~ /^#[0-9a-fA-F]{6}$/;
    my $flat = Imager->new(xsize => $img->getwidth, ysize => $img->getheight,
                           channels => $img->getchannels == 4 ? 3 : 1);
    $flat->box(filled => 1, color => $bg);
    $flat->rubthrough(src => $img) or _fail('conversionFailed', 'flatten failed');
    $img = $flat;
  }

  if ($recipe->{stripMetadata}) {
    $img->deltag(name => $_->[0]) for grep { $_->[0] !~ /^i_/ } $img->tags;
  }

  my $out = '';
  my %wopt = (data => \$out, type => $IMAGER_TYPE{$type});
  if (defined $recipe->{quality}) {
    _fail('invalidProperties', 'quality must be 1..100')
      if $recipe->{quality} < 1 || $recipe->{quality} > 100;
    $wopt{jpegquality} = $recipe->{quality} if $type eq 'image/jpeg';
    $wopt{webp_quality} = $recipe->{quality} if $type eq 'image/webp';
  }
  $img->write(%wopt) or _fail('conversionFailed', 'could not write the image: ' . $img->errstr);
  return ($out, $type);
}

# ImageData for Blob/get (Section 5), or undef when the blob is not an image
# or video we can read.
sub image_data {
  my ($bytes, $type) = @_;
  $type //= detect_type($bytes) // '';
  return undef unless $type =~ m{^(image|video)/};
  my %d = (width => undef, height => undef, orientation => undef, date => undef,
           gps => undef, duration => undef, comment => undef);
  my $found = 0;
  if ($type =~ m{^image/}) {
    my ($w, $h) = Image::Size::imgsize(\$bytes);
    if (defined $w && defined $h) { @d{qw(width height)} = (0 + $w, 0 + $h); $found = 1 }
  }
  if ($HAVE{'Image::ExifTool'}) {
    my $info = eval {
      Image::ExifTool::ImageInfo(\$bytes,
        [qw(Orientation DateTimeOriginal OffsetTimeOriginal CreateDate GPSLatitude GPSLongitude
            Duration ImageDescription UserComment ImageWidth ImageHeight)],
        { PrintConv => 0, Duplicates => 0 });
    } || {};
    $found = 1 if %$info && !$info->{Error};
    $d{width}  //= 0 + $info->{ImageWidth}  if defined $info->{ImageWidth};
    $d{height} //= 0 + $info->{ImageHeight} if defined $info->{ImageHeight};
    $d{orientation} = 0 + $info->{Orientation}
      if defined $info->{Orientation} && $info->{Orientation} =~ /^[1-8]$/;
    my $dt = $info->{DateTimeOriginal} // $info->{CreateDate};
    if (defined $dt && $dt =~ /^(\d{4}):(\d\d):(\d\d) (\d\d):(\d\d):(\d\d)/) {
      my $iso = "$1-$2-$3T$4:$5:$6";
      my $off = $info->{OffsetTimeOriginal} // '';
      if ($off =~ /^([+-])(\d\d):(\d\d)$/) {
        require Time::Local;
        my $epoch = Time::Local::timegm($6, $5, $4, $3, $2 - 1, $1) - ($1 eq '-' ? -1 : 1) * ($2 * 3600 + $3 * 60);
        $iso = _iso8601($epoch);
      }
      else { $iso .= 'Z' }
      $d{date} = $iso;
    }
    if (defined $info->{GPSLatitude} && defined $info->{GPSLongitude}) {
      $d{gps} = { latitude => 0 + $info->{GPSLatitude}, longitude => 0 + $info->{GPSLongitude} };
    }
    $d{duration} = 0 + $info->{Duration} if defined $info->{Duration} && $info->{Duration} =~ /^[\d.]+$/;
    my $c = $info->{ImageDescription} // $info->{UserComment};
    $d{comment} = "$c" if defined $c && length $c;
  }
  return $found ? \%d : undef;
}

1;
