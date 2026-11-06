#!/usr/bin/perl
# t/templates-escape.t -- every value a template prints is escaped. Template
# Toolkit does not escape by itself, and these pages print what users typed
# (a password, a host, an OAuth error from a query string) back to them.
use strict;
use warnings;
use Test::More;
use File::Basename qw(basename);

my $dir = 'htdocs';
my @templates = sort glob("$dir/*.html");
ok(@templates, 'found the templates');

# Directives print nothing themselves; anything else must end in a filter.
my $directive = qr/^\s*-?\s*(?:IF|ELSE|ELSIF|END|UNLESS|FOREACH|SET|INCLUDE|WRAPPER|BLOCK|#)\b/;
my $filtered  = qr/(?<!\|)\|(?!\|)\s*(?:html|uri|js)\s*-?\s*$/;

for my $file (@templates) {
  my $text = do { local (@ARGV, $/) = ($file); <> };
  my @bare;
  while ($text =~ /\[%(.*?)%\]/gs) {
    my $inner = $1;
    next if $inner =~ $directive or $inner =~ $filtered;
    (my $show = $inner) =~ s/^\s+|\s+$//g;
    push @bare, $show;
  }
  is_deeply(\@bare, [], basename($file) . ': every printed value is escaped');
}

done_testing;
