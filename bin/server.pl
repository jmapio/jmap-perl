#!/usr/bin/perl -w

use lib '/home/jmap/jmap-perl';

#use Mail::IMAPTalk qw(:trace);
use HTML::GenerateUtil qw(escape_html escape_uri);
use strict;
use warnings;
use Cookie::Baker;
use Data::UUID::LibUUID;
use HTTP::Tiny;
use AnyEvent;
use AnyEvent::Gmail;
use AnyEvent::IMAP;
use Data::Dumper;
use AnyEvent::HTTPD;
use AnyEvent::Handle;
use AnyEvent::Socket;
use AnyEvent::Util;
use AnyEvent::HTTP;
use JMAP::Sync::Gmail;
use JSON::XS qw(decode_json);
use Encode qw(encode_utf8);
use Template;
my $TT = Template->new(INCLUDE_PATH => '/home/jmap/jmap-perl/htdocs');

my $json = JSON::XS->new->utf8->canonical();

sub mkerr {
  my $req = shift;
  return sub {
    my $error = shift;
    my $html = '';
    $error =~ s{at (/|bin/).*}{}s;
    $TT->process("error.html", { error => $error }, \$html) || die $Template::ERROR;
    $req->respond({content => ['text/html', $html]});
  };
}

my %idler;

sub idler {
  my $accountid = shift;
  my $edgecb = shift;

  send_backend_request("$accountid:sync", 'gettoken', $accountid, sub {
    my ($data) = @_;
    if ($data) {
      my $imap = $data->[0] eq 'imap.gmail.com' ? AnyEvent::Gmail->new(
        host => 'imap.gmail.com',
        user => $data->[1],
        token => $data->[2],
        port => 993,
        ssl => 1,
      ) : AnyEvent::IMAP->new(
        host => $data->[0],
        user => $data->[1],
        pass => $data->[2],
        port => 993,
        ssl => 1,
      );

      $imap->reg_cb(
        connect => sub {
          $imap->login()->cb(sub {
            my ($ok, $line) = shift->recv;
            warn "LOGIN $data->[1]: $ok @$line\n";
            if ($ok) {
              setup_examine($edgecb, $imap);
            }
          });
        },
        disconnect => sub {
          if ($idler{$accountid}) {
            idler($accountid, $edgecb);
          }
          # otherwise: let it go
        }
      );
      $imap->connect();

      $idler{$accountid}{idler} = $imap;

      $idler{$accountid}{dav} = AnyEvent->timer(after => 1, interval => 300, cb => sub {
        send_backend_request("$accountid:dav", 'davsync', $accountid, sub { });
      });
    }
    else {
      # clean up so next attempt will try again
      delete $idler{$accountid};
    }
  });
}

sub setup_examine {
  my $edgecb = shift;
  my $imap = shift;

  $imap->send_cmd('SELECT "INBOX"', sub {
    $edgecb->("initial");

    setup_idle($edgecb, $imap);
  });
}

sub make_timer {
  my $imap = shift;
  return AnyEvent->timer(after => 840, cb => sub { # 29 minutes
    pop @{$imap->{socket}{_queue}};  # there needs to be an interface for this!
    $imap->{socket}->push_write("DONE\r\n");
  });
}

sub setup_idle {
  my $edgecb = shift;
  my $imap = shift;

  my $timer = make_timer($imap);
  # XXX - how does it know that IDLE has done?
  $imap->send_cmd("IDLE", sub {
    setup_idle($edgecb, $imap);
  });
  read_idle_line($edgecb, $imap, $timer);
}

sub read_idle_line {
  my $edgecb = shift;
  my $imap = shift;
  my $timer = shift;

  $imap->{socket}->push_read(line => sub {
    my $handle = shift;
    my $line = shift;
    if ($line =~ m/^\*/) {
      $timer = make_timer($imap);
      $edgecb->($line);
    }
    read_idle_line($edgecb, $imap, $timer);
  });
}

my $httpd = AnyEvent::HTTPD->new (port => 9000);

my %backend;

$httpd->reg_cb (
  '/jmap' => \&do_jmap,
  '/upload' => \&do_upload,
  '/raw' => \&do_raw,
  '/register' => \&do_register,
  '/delete' => \&do_delete,
  '/cb/google' => \&do_cb_google,
  '/signup' => \&do_signup,
  '/files' => \&do_files,
  '/home' => \&home_page,
);

my %waiting;

sub mk_json {
  my $accountid = shift;
  return sub {
    my ($hdl, $res) = @_;
    if ($res->[0] eq 'push') {
      PushEvent($accountid, event => "state", data => $res->[1]);
    }
    elsif ($res->[0] eq 'bye') {
      print "SERVER CLOSING $accountid\n";
      delete $backend{$accountid};
    }
    elsif ($waiting{$accountid}{$res->[2]}) {
      if ($res->[0] eq 'error') {
        $waiting{$accountid}{$res->[2]}[1]->($res->[1]);
        # start again...
        print "ERROR $res->[1] on $accountid (dropping backend)\n";
        delete $backend{$accountid};
      }
      else {
        $waiting{$accountid}{$res->[2]}[0]->($res->[1]);
      }
      delete $waiting{$accountid}{$res->[2]};
    }
    else {
      # otherwise just drop it
      print "WEIRD RESPONSE $accountid: $res->[0]\n";
    }
    # gotta get the next one
    $hdl->push_read(json => mk_json($accountid));
  };
}

sub get_backend {
  my $accountid = shift;

  # XXX - play the ping_pong game with callbacks?
  unless ($backend{$accountid}) {
    $backend{$accountid} = [AnyEvent::Handle->new(
      connect => ['127.0.0.1', 5000],
      on_error => sub {
        print "CLOSING ON ERROR $accountid\n";
        delete $backend{$accountid};
      },
      on_disconnect => sub {
        print "CLOSING ON DISCONNECT $accountid\n";
        delete $backend{$accountid};
      },
    ), 0];
    $backend{$accountid}[0]->push_write("$accountid\n");
    $backend{$accountid}[0]->push_read(json => mk_json($accountid));
  }
  return $backend{$accountid};
}

sub send_backend_request {
  my $accountid = shift;
  my $request = shift;
  my $args = shift;
  my $cb = shift;
  my $errcb = shift;
  my $backend = get_backend($accountid);
  my $cmd = "#" . $backend->[1]++;
  warn "SENDING $accountid $request\n";
  $waiting{$accountid}{$cmd} = [$cb || sub {return 1}, $errcb || sub {return 1}];
  $backend->[0]->push_write(json => [$request, $args, $cmd]);
}

sub do_files {
  my ($httpd, $req) = @_;

  my $uri = $req->url();
  my $path = $uri->path();

  return not_found($req) unless $path =~ m{^/files/([^/]+)/(.*)$};

  my $accountid = $1;
  my $id = $2;

  # fetch existing URL? */
  if ($id) {
    return invalid_request($req) unless lc $req->method eq 'get';

    $httpd->stop_request();

    send_backend_request($accountid, 'download', $id, sub {
      my ($data) = @_;
      if ($data->[0]) {
        my %headers = ('Content-Type' => $data->[0]);
        my $isdownload = $req->parm('download');
        $headers{"Content-Disposition"} = "attachment" if $isdownload;

        $req->respond([200, 'ok', \%headers, $data->[1]]);
      }
      else {
        not_found($req)
      }
      return 1;
    }, mkerr($req));
  }
  else {
    return invalid_request($req) unless lc $req->method eq 'post';

    my $type = $req->headers->{"content-type"};
    return invalid_request($req) unless $type;

    my $data = [ $type, $req->content() ];

    $httpd->stop_request();

    send_backend_request($accountid, 'upload', $data, sub {
      my $res = shift;
      my $id = delete $res->{id};
      $res->{url} = "/files/$accountid/$id";
      my $html = encode_utf8($json->encode($res));
      $req->respond ({ content => ['application/json', $html] });
      return 1;
    }, mkerr($req));
  }
}

sub do_raw {
  my ($httpd, $req) = @_;

  my $isdownload = $req->parm('download');

  my $uri = $req->url();
  my $path = $uri->path();

  return invalid_request($req) unless lc $req->method eq 'get';
  return not_found($req) unless $path =~ m{^/raw/([^/]+)/(.*)};

  my $accountid = $1;
  my $selector = $2;

  prod_idler($accountid);

  $httpd->stop_request();

  send_backend_request($accountid, 'raw', $selector, sub {
    my ($data) = @_;
    if ($data->[0]) {
      my %headers = ('Content-Type' => $data->[0]);
      my $Disposition = undef;
      $Disposition = "attachment" if $isdownload;
      if (defined($data->[2])) {
        $Disposition ||= "inline";
        my $FileNameEnc = escape_uri($data->[2]);
        $Disposition .= qq{; filename="$FileNameEnc"; filename*=UTF-8''$FileNameEnc};
      }
      $headers{"Content-Disposition"} = $Disposition if $Disposition;

      $req->respond([200, 'ok', \%headers, $data->[1]]);
    }
    else {
      not_found($req)
    }
    return 1;
  }, mkerr($req));
}

sub do_upload {
  my ($httpd, $req) = @_;

  my $uri = $req->url();
  my $path = $uri->path();

  return not_found($req) unless $path =~ m{^/upload/([^/]+)};

  my $accountid = $1;

  return client_page($req, $accountid) unless lc $req->method eq 'post';

  prod_idler($accountid);

  my $content = $req->content();
  return invalid_request($req) unless $content;

  my $type = $req->headers->{"content-type"};

  $httpd->stop_request();

  send_backend_request($accountid, 'upload', [$type, $content], sub {
    my $res = shift;
    my $response = encode_utf8($json->encode($res));
    $req->respond ({ content => ['application/json', $response] });
    return 1;
  }, mkerr($req));
}

sub do_jmap {
  my ($httpd, $req) = @_;

  my $uri = $req->url();
  my $path = $uri->path();

  return not_found($req) unless $path =~ m{^/jmap/([^/]+)};

  my $accountid = $1;

  return client_page($req, $accountid) unless lc $req->method eq 'post';

  prod_idler($accountid);

  my $content = $req->content();
  return invalid_request($req) unless $content;
  my $request = eval { $json->decode($content) };
  return invalid_request($req) unless ($request and ref($request) eq 'ARRAY');

  $httpd->stop_request();

  send_backend_request($accountid, 'jmap', $request, sub {
    my $res = shift;
    my $html = encode_utf8($json->encode($res));
    $req->respond (['200', 'ok', {
      'Content-Type' => 'application/json',
      'Access-Control-Allow-Origin' => '*',
    }, $html]);
    return 1;
  }, mkerr($req));
}

sub client_page {
  my $req = shift;
  my $accountid = shift;

  send_backend_request($accountid, 'getinfo', $accountid, sub {
    my $data = shift;

    prod_idler($accountid);
    send_backend_request($accountid, 'syncall');

    my $html = '';
    $TT->process("landing.html", {
      info => "Account: <b>$data->[0] ($data->[1])</b>",
      uuid => $accountid,
      jmaphost => $ENV{jmaphost},
     }, \$html) || die $Template::ERROR;
    $req->respond({content => ['text/html', $html]});
  }, sub {
    my $cookie = bake_cookie("jmap_$accountid", {value => '', path => '/'});
    $req->respond([301, 'redirected', { 'Set-Cookie' => $cookie, Location => "https://$ENV{jmaphost}/" }, "Redirected"]);
  });
}

sub home_page {
  my ($httpd, $req) = @_;

  my $sessiontext = '';
  my @text;
  my $cookies = crush_cookie($req->headers->{cookie});
  my %ids;
  foreach my $id (keys %$cookies) {
    next unless $id =~ m/^jmap_(.*)/;
    next unless $cookies->{$id};
    $ids{$1} = $cookies->{$id};
  }
  if (keys %ids) {
    $sessiontext = <<EOF;
<table border="1">
<tr>
 <th>Logged in sessions</th>
</tr>
EOF
    foreach my $key (sort keys %ids) {
      $sessiontext .= qq{<tr>\n <td><a href="https://$ENV{jmaphost}/jmap/$key/">$ids{$key}</a>\n </td>\n</tr>\n};
    }
    $sessiontext .= "</table>";
  }
  my $html = '';
  $TT->process("index.html", {
    sessions => $sessiontext,
    jmaphost => $ENV{jmaphost},
   }, \$html) || die $Template::ERROR;
  $req->respond({content => ['text/html', $html]});
}

sub need_auth {
  my $req = shift;
  $req->respond([403, 'need auth', { 'Content-Type' => 'text/plain' }, 'need auth']);
}

sub not_found {
  my $req = shift;
  $req->respond([404, 'not found', { 'Content-Type' => 'text/plain' }, 'not found']);
}

sub invalid_request {
  my $req = shift;
  $req->respond([400, 'invalid request', { 'Content-Type' => 'text/plain' }, 'invalid request']);
}

sub server_error {
  my $req = shift;
  $req->respond([500, 'server error', { 'Content-Type' => 'text/plain' }, 'server error']);
}

my %PushMap;

# Send a keepalive ping event down every eventsource connection
#  every this many seconds. This value is a tradeoff to stop
#  clients losing connections (e.g. NAT timeouts), but to allow
#  clients to go to sleep (e.g. phones/tablets)
# The client may also depend on this value to detect if a
#  connection has been broken, so don't increase without checking
#  the AJAX client as well.
use constant KEEPALIVE_TIME => 300;
use constant KEEPIDLE_TIME => 300;

# EventSource connection headers
my $EventSourceHeaders = <<EOF;
HTTP/1.0 200 OK
Cache-Control: no-cache, no-store, no-cache, must-revalidate
Pragma: no-cache
Connection: close
Content-Type: text/event-stream; charset=utf-8

EOF
$EventSourceHeaders =~ s/\n/\r\n/g;

# not using httpd because it's a long running connection
tcp_server('127.0.0.1', '9001', sub {
  my ($fh) = @_;
  my $Handle = AnyEvent::Handle->new(fh => $fh);
  $Handle->on_error(sub { undef $Handle; });
  $Handle->on_eof(sub { undef $Handle; });
  $Handle->push_read(line => "\r\n\r\n", \&HandleEventSource);
});

# Keep-alive timer
my $Timer = AnyEvent->timer(
  after => 29,
  interval => 29,
  cb => \&HandleKeepAlive
);

sub HandleEventSource {
  my ($Handle, $Line, $Eol) = @_;

  # At this point we have a proxied connection from the frontend
  #  and have read the headers so time to store this handler
  #  and get ready to send events
  my ($Request, @Headers) = split /\r?\n/, $Line;

  $Request =~ m{^GET /events/(\S+) HTTP}
    || return ShutdownHandle($Handle, "500 Invalid request\r\n");
  my $Channel = $1;

  # Set channel cleanup handler
  $Handle->on_eof(\&ShutdownPushChannel);
  $Handle->on_error(\&ShutdownPushChannel);
  # Need this, otherwise eof callback is never called. Just empty read buffer so it doesn't grow
  $Handle->on_read(sub { $_[0]->{rbuf} = ''; });

  $Handle->{Channel} = $Channel;

  my $Fd = fileno $Handle->fh;

  $PushMap{$Channel}{handles}{$Fd} = $Handle;
  $PushMap{$Channel}{lastwrite} ||= time();

  print "NEW PUSH CONNECTION $Channel $Fd\n";
  $Handle->push_write($EventSourceHeaders);
  $Handle->push_write(": new event source connection\r\n\r\n");

  send_backend_request($Channel, 'getstate', undef, sub {
    my ($data) = shift;
    PushToHandle($Handle, event => 'state', data => $data);

    # start up an idler for this connection
    prod_idler($Channel);
  });
}


sub prod_backfill {
  my $accountid = shift;
  my $force = shift;
  return if (not $force and $idler{$accountid}{backfilling});
  $idler{$accountid}{backfilling} = 1;
    
  my $timer;
  $timer = AnyEvent->timer(after => 10, cb => sub {
    send_backend_request("$accountid:backfill", 'backfill', $accountid, sub {
      $timer = undef;
      prod_backfill($accountid, @_);
      # keep the idler running while we're backfilling
      $idler{$accountid}{lastused} = time();
    });
  });
}

sub prod_idler {
  my $accountid = shift;

  unless ($idler{$accountid}) {
    idler($accountid,
      sub {
        send_backend_request("$accountid:sync", 'sync', $accountid);
      },
    );
  }

  prod_backfill($accountid);

  $idler{$accountid}{lastused} = time();
}

sub PushToHandle {
  my $Handle = shift;
  my %vals = @_;
  print "PUSH EVENT " . $json->encode(\%vals) . "\n";
  my @Lines = map { "$_: " . (ref($vals{$_}) ? $json->encode($vals{$_}) : $vals{$_}) } keys %vals;
  $Handle->push_write(join("\r\n", @Lines) . "\r\n\r\n");
}

sub PushEvent {
  my $Channel = shift;
  $Channel =~ s/:.*//;
  my %vals = @_;
  foreach my $Fd (keys %{$PushMap{$Channel}{handles}}) {
    my $ToHandle = $PushMap{$Channel}{handles}{$Fd};
    PushToHandle($ToHandle, %vals);
  }
  $PushMap{$Channel}{lastwrite} = time();
}

sub ShutdownPushChannel {
  my ($Handle) = @_;

  my $Channel = $Handle->{Channel};
  my $Fd = fileno $Handle->fh;
  print "CLOSING PUSH CONNECTION $Channel $Fd\n";
  delete $PushMap{$Channel}{handles}{$Fd};
  unless (keys %{$PushMap{$Channel}{handles}}) {
    print "LAST CHANNEL FOR $Channel, closing\n";
    delete $PushMap{$Channel};
  }

  $Handle->destroy();
}

sub ShutdownHandle {
  my ($Handle, $Msg) = @_;
  $Handle->push_write($Msg) if $Msg;
  $Handle->on_drain(sub { $Handle->destroy(); });
}

sub HandleKeepAlive {
  my $Now = time();
  foreach my $Channel (keys %PushMap) {
    next if $PushMap{$Channel}{lastwrite} >= $Now - KEEPALIVE_TIME;
    PushEvent($Channel, event => "ping", data => {servertimestamp => $Now});
  }

  foreach my $accountid (sort keys %idler) {
    next if $PushMap{$accountid}; # nothing to do
    if ($idler{$accountid}{lastused} < $Now - KEEPIDLE_TIME) {
      my $old = $idler{$accountid}{idler};
      my $sync = delete $backend{"$accountid:sync"};
      my $dav = delete $backend{"$accountid:dav"};
      my $backfill = delete $backend{"$accountid:backfill"};
      delete $idler{$accountid};
      eval { $old->disconnect() };
      eval { ShutdownHandle($sync) };
      eval { ShutdownHandle($dav) };
      eval { ShutdownHandle($backfill) };
    }
  }
}

sub do_register {
  my ($httpd, $req) = @_;
  my $O = JMAP::Sync::Gmail::O();
  $req->respond({redirect => $O->start(new_uuid_string())});
};

sub do_delete {
  my ($httpd, $req) = @_;

  my $uri = $req->url();
  my $path = $uri->path();

  return not_found($req) unless $path =~ m{^/delete/([^/]+)};

  my $accountid = $1;
  if ($accountid) {
    send_backend_request($accountid, 'delete', $accountid, sub {
      my $cookie = bake_cookie("jmap_$accountid", {value => '', path => '/'});
      $req->respond([301, 'redirected', { 'Set-Cookie' => $cookie, Location => "https://$ENV{jmaphost}/" }, "Redirected"]);
    }, mkerr($req));
  }
};

sub do_signup {
  my ($httpd, $req) = @_;

  my $uri = $req->url();
  my $path = $uri->path();

  my %opts;
  foreach my $key (qw(username password imapHost imapPort imapSSL smtpHost smtpPort smtpSSL caldavURL carddavURL force)) {
    $opts{$key} = $req->parm($key);
  }

  my $accountid = new_uuid_string();
  send_backend_request($accountid, 'signup', \%opts, sub {
    my ($data) = @_;
    warn Dumper($data);
    if ($data && $data->[0] eq 'done') {
      send_backend_request($data->[0], 'sync', $data->[1]);
      my $cookie = bake_cookie("jmap_$data->[1]", {
        value => $data->[2],
        path => '/',
        expires => '+3M',
      });
      $req->respond([301, 'redirected', { 'Set-Cookie' => $cookie, Location => "https://$ENV{jmaphost}/jmap/$data->[1]" },
                "Redirected"]);
      delete $backend{$accountid} unless $data->[1] eq $accountid;
    }
    else {
      my $html = '';
      $TT->process("signup.html", $data->[1], \$html) || die $Template::ERROR;
      $req->respond({content => ['text/html', $html]});
    }
    return 1;
  }, mkerr($req));
}

sub do_cb_google {
  my ($httpd, $req) = @_;

  my $accountid = $req->parm('state');
  my $code = $req->parm('code');

  send_backend_request($accountid, 'cb_google', $code, sub {
    my ($data) = @_;
    if ($data) {
      my $cookie = bake_cookie("jmap_$data->[0]", {
        value => $data->[1],
        path => '/',
        expires => '+3M',
      });
      $req->respond([301, 'redirected', { 'Set-Cookie' => $cookie, Location => "https://$ENV{jmaphost}/jmap/$data->[0]" },
                "Redirected"]);
      delete $backend{$accountid} unless $data->[0] eq $accountid;
      send_backend_request($data->[0], 'sync', $data->[0]);
    }
    else {
      not_found($req);
    }
    return 1;
  }, mkerr($req));
};

AnyEvent->condvar->recv;

