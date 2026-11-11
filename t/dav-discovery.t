#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use lib '.';

use JMAP::DavDiscovery;

# Fake DNS: name => [ records ] for SRV, name => [ strings ] for TXT
sub fakes {
  my (%dns) = @_;
  my $srv = sub { @{ $dns{srv}{$_[0]} || [] } };
  my $txt = sub { @{ $dns{txt}{$_[0]} || [] } };
  return (srv => $srv, txt => $txt);
}

# --- srv_url ---

is(JMAP::DavDiscovery::srv_url(service => 'caldav', domain => 'example.com', fakes()),
   undef, 'no SRV record: nothing');

is(JMAP::DavDiscovery::srv_url(service => 'caldav', domain => 'example.com',
     fakes(srv => { '_caldavs._tcp.example.com' => [ { target => 'dav.example.com', port => 443 } ] })),
   'https://dav.example.com', 'caldavs on 443: no port in the URL');

is(JMAP::DavDiscovery::srv_url(service => 'carddav', domain => 'example.com',
     fakes(srv => { '_carddavs._tcp.example.com' => [ { target => 'dav.example.com.', port => 8443 } ] })),
   'https://dav.example.com:8443', 'other port kept, trailing dot of the target dropped');

is(JMAP::DavDiscovery::srv_url(service => 'caldav', domain => 'example.com',
     fakes(srv => { '_caldav._tcp.example.com' => [ { target => 'dav.example.com', port => 80 } ] })),
   'http://dav.example.com', 'plain _caldav gives http');

is(JMAP::DavDiscovery::srv_url(service => 'caldav', domain => 'example.com',
     fakes(srv => { '_caldavs._tcp.example.com' => [ { target => 'a.example.com', port => 443 } ],
                    '_caldav._tcp.example.com'  => [ { target => 'b.example.com', port => 80 } ] })),
   'https://a.example.com', 'caldavs wins over caldav');

is(JMAP::DavDiscovery::srv_url(service => 'caldav', domain => 'example.com',
     fakes(srv => { '_caldavs._tcp.example.com' => [ { target => 'dav.example.com', port => 443 } ] },
           txt => { '_caldavs._tcp.example.com' => [ 'v=1', 'path=/dav/cal' ] })),
   'https://dav.example.com/dav/cal', 'TXT path is the context path (RFC 6764 S4)');

is(JMAP::DavDiscovery::srv_url(service => 'caldav', domain => 'example.com',
     fakes(srv => { '_caldavs._tcp.example.com' => [ { target => 'dav.example.com', port => 443 } ] },
           txt => { '_caldavs._tcp.example.com' => [ 'path=remote.php/dav' ] })),
   'https://dav.example.com/remote.php/dav', 'a path without a leading slash gets one');

# --- guess_urls ---

is_deeply([ JMAP::DavDiscovery::guess_urls(domain => 'Example.com', hosts => [ 'imap.example.com' ]) ],
          [ 'https://example.com/', 'https://imap.example.com/' ], 'domain first, then the IMAP host');
is_deeply([ JMAP::DavDiscovery::guess_urls(domain => 'example.com', hosts => [ 'EXAMPLE.com.' ]) ],
          [ 'https://example.com/' ], 'the same host only once');
is_deeply([ JMAP::DavDiscovery::guess_urls(domain => 'example.com', hosts => [ undef, '', 'x/y', 'a b' ]) ],
          [ 'https://example.com/' ], 'missing and malformed hosts are skipped');

# --- discover ---

{
  my @probed;
  my %works = ('caldav https://imap.example.com/' => 1, 'carddav https://example.com/' => 1);
  my $probe = sub { push @probed, "$_[0] $_[1]"; $works{"$_[0] $_[1]"} };
  my $detail = { imapHost => 'imap.example.com' };
  my $found = JMAP::DavDiscovery::discover(detail => $detail, domain => 'example.com',
                                           fakes(), probe => $probe);
  is($detail->{caldavURL}, 'https://imap.example.com/', 'caldav found on the IMAP host');
  is($detail->{carddavURL}, 'https://example.com/', 'carddav found on the domain');
  is_deeply($found, { caldavURL => 'wellknown', carddavURL => 'wellknown' }, 'both reported as well-known');
  is_deeply(\@probed, [ 'caldav https://example.com/', 'caldav https://imap.example.com/',
                        'carddav https://example.com/' ], 'probing stops at the first that works');
}

{
  my @probed;
  my $detail = { imapHost => 'imap.example.com' };
  JMAP::DavDiscovery::discover(detail => $detail, domain => 'example.com', fakes(),
                               probe => sub { push @probed, $_[1]; 0 });
  ok(!$detail->{caldavURL} && !$detail->{carddavURL}, 'nothing answers: both stay empty');
  is(scalar @probed, 4, 'two hosts tried per service');
}

{
  my $probed = 0;
  my $detail = { caldavURL => 'https://mine.example.net/', imapHost => 'imap.example.com' };
  my $found = JMAP::DavDiscovery::discover(detail => $detail, domain => 'example.com',
    fakes(srv => { '_carddavs._tcp.example.com' => [ { target => 'dav.example.com', port => 443 } ] }),
    probe => sub { $probed++; 1 });
  is($detail->{caldavURL}, 'https://mine.example.net/', 'a URL already given is kept');
  is($detail->{carddavURL}, 'https://dav.example.com', 'SRV used as published');
  is_deeply($found, { carddavURL => 'srv' }, 'only carddav reported, as srv');
  is($probed, 0, 'SRV results are not probed');
}

{
  my $detail = {};
  JMAP::DavDiscovery::discover(detail => $detail, domain => 'example.com', fakes());
  ok(!exists $detail->{caldavURL}, 'without a probe nothing is guessed');
}

# --- autoconfig_urls ---

my $xml = <<'XML';
<clientConfig version="1.1">
  <emailProvider id="example.com">
    <incomingServer type="imap"><hostname>imap.example.com</hostname></incomingServer>
  </emailProvider>
  <addressBook type="carddav">
    <username>%EMAILADDRESS%</username>
    <serverURL>https://dav.example.com/addressbooks/%EMAILLOCALPART%/</serverURL>
  </addressBook>
  <calendar type="caldav">
    <serverURL> https://dav.example.com/caldav?a=1&amp;b=2 </serverURL>
  </calendar>
</clientConfig>
XML

is_deeply(JMAP::DavDiscovery::autoconfig_urls($xml, 'jo@example.com'),
          { caldavURL  => 'https://dav.example.com/caldav?a=1&b=2',
            carddavURL => 'https://dav.example.com/addressbooks/jo/' },
          'autoconfig calendar and addressBook blocks, placeholders filled');
is_deeply(JMAP::DavDiscovery::autoconfig_urls(
            '<calendar type="caldav"><serverURL>https://x/%UNKNOWN%/</serverURL></calendar>'
          . '<addressBook type="carddav"><serverURL>ldap://x/</serverURL></addressBook>', 'jo@example.com'),
          {}, 'unknown placeholder and non-http URL dropped');
is_deeply(JMAP::DavDiscovery::autoconfig_urls('<clientConfig/>', 'jo@example.com'), {}, 'no DAV blocks: nothing');

done_testing;
