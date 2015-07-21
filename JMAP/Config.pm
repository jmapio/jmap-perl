#!/usr/bin/perl -c

use strict;
use warnings;

package JMAP::Config;

use base 'Exporter';

our @EXPORT = qw(config);

use JSON::XS qw(encode_json decode_json);
use IO::All;

our $CONFIG;

sub config {
  unless ($CONFIG) {
    my $file = "/etc/jmap_proxy.conf";
    $CONFIG = eval { decode_json(io->file($ENV{JMAPCONF} || $file)->slurp) };
    die "NEED config $file or ENV JMAPCONF" unless $CONFIG;
  }
  my $name = shift;
  return $name ? $CONFIG->{$name} : $CONFIG;
}

1;
