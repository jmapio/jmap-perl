#!/usr/bin/perl -c

use strict;
use warnings;

package JMAP::DavDiscovery;

# Finds an account's CalDAV and CardDAV URLs at signup (RFC 6764).
#
# 1. SRV _caldavs._tcp / _caldav._tcp (and the carddav pair) on the address's
#    domain, with the context path from the TXT record of the same name (S4).
#    The domain's owner published these, so they are taken as they are.
# 2. Otherwise the well-known URI (S5) on the address's domain, then on the IMAP
#    host. These are guesses, so one is only kept once the injected probe has
#    logged in there and found a principal and a home set. Without that check,
#    every account would advertise calendars and contacts that never sync.
#
# DNS and HTTP are injected (srv, txt, probe), so this does no I/O itself and
# t/dav-discovery.t drives it with fakes.

our @SERVICES = qw(caldav carddav);

# srv->($name) returns the usable records as { target, port } hashes, best
# first; txt->($name) returns the TXT strings. Either may return nothing.
sub srv_url {
  my (%a) = @_;
  my ($service, $domain) = @a{qw(service domain)};
  for my $try ([ "_${service}s._tcp", 'https', 443 ],
               [ "_${service}._tcp",  'http',  80  ]) {
    my ($label, $scheme, $defport) = @$try;
    my $name = "$label.$domain";
    my ($rec) = $a{srv}->($name) or next;
    my $url = "$scheme://$rec->{target}";
    $url =~ s/\.$//;   # an absolute DNS name is not a URL host
    $url .= ":$rec->{port}" if $rec->{port} && $rec->{port} != $defport;
    my ($path) = grep { defined && length }
                 map  { m{^path=(.*)$} ? $1 : undef } ($a{txt} ? $a{txt}->($name) : ());
    if (defined $path) {
      $path = "/$path" unless $path =~ m{^/};
      $url .= $path;
    }
    return $url;
  }
  return;
}

# The hosts worth trying the well-known URI on, as base URLs. Net::DAVTalk, given
# a URL with no path, starts at /.well-known/<service> itself, so the sync later
# repeats exactly what the probe did.
sub guess_urls {
  my (%a) = @_;
  my %seen;
  return map  { "https://$_/" }
         grep { !$seen{$_}++ }
         map  { my $h = lc $_; $h =~ s/\.$//; $h }
         grep { defined && m{^[A-Za-z0-9.-]+$} && m{[A-Za-z0-9]} }
         ($a{domain}, @{ $a{hosts} || [] });
}

# Fills in $detail->{caldavURL} and {carddavURL} that are still empty. A value
# already there (the user's, a provider default, autoconfig's) is never touched.
# Returns the fields it filled, with how each was found ('srv' or 'wellknown').
sub discover {
  my (%a) = @_;
  my $detail = $a{detail};
  my $domain = $a{domain};
  my %found;
  for my $service (@SERVICES) {
    my $field = "${service}URL";
    next if $detail->{$field};
    if (my $url = srv_url(service => $service, domain => $domain,
                          srv => $a{srv}, txt => $a{txt})) {
      $detail->{$field} = $url;
      $found{$field} = 'srv';
      next;
    }
    next unless $a{probe};
    for my $url (guess_urls(domain => $domain, hosts => [ $detail->{imapHost} ])) {
      next unless $a{probe}->($service, $url);
      $detail->{$field} = $url;
      $found{$field} = 'wellknown';
      last;
    }
  }
  return \%found;
}

# The <calendar type="caldav"> and <addressBook type="carddav"> blocks of a
# Mozilla autoconfig file (config-v1.1.xml). Thunderbird documents them but does
# not read them, yet some providers publish them. Placeholders are filled in
# from $email; a URL left with one it doesn't know, or that isn't http(s), is
# dropped.
sub autoconfig_urls {
  my ($xml, $email) = @_;
  return {} unless defined $xml;
  my ($local, $domain) = split /\@/, ($email // ''), 2;
  my %var = (
    EMAILADDRESS   => $email  // '',
    EMAILLOCALPART => $local  // '',
    EMAILDOMAIN    => $domain // '',
  );
  my %out;
  for my $block ([ 'calendar',    'caldav',  'caldavURL'  ],
                 [ 'addressBook', 'carddav', 'carddavURL' ]) {
    my ($tag, $type, $field) = @$block;
    my ($body) = $xml =~ m{<$tag\s+type="$type"[^>]*>(.*?)</$tag>}s or next;
    my ($url) = $body =~ m{<serverURL>\s*(.*?)\s*</serverURL>}s or next;
    $url =~ s/&amp;/&/g;
    $url =~ s/%(EMAILADDRESS|EMAILLOCALPART|EMAILDOMAIN)%/$var{$1}/g;
    next if $url =~ /%[A-Z]+%/ or $url !~ m{^https?://[^/\s]+};
    $out{$field} = $url;
  }
  return \%out;
}

1;
