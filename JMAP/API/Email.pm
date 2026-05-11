package JMAP::API;
use strict;
use warnings;

use JSON::XS;
use JSON;
use Data::JSEmail;
use Encode;
use HTML::GenerateUtil qw(escape_html);
use Date::Parse;
use B ();

my $json = JSON::XS->new->utf8->canonical();

sub _post_sort {
  my $Self = shift;
  my $data = shift;
  my $sortargs = shift;
  my $storage = shift;

  my %fieldmap = (
    id => ['msgid', 0],
    receivedAt => ['internaldate', 1],
    sentAt => ['msgdate', 1],
    size => ['msgsize', 1],
    isunread => ['isUnread', 1],
    subject => ['sortsubject', 0],
    from => ['msgfrom', 0],
    to => ['msgto', 0],
  );

  my @res = sort {
    foreach my $arg (@$sortargs) {
      my $res = 0;
      my $field = $arg->{property};
      my $map = $fieldmap{$field};
      if ($map) {
        if ($map->[1]) {
          $res = $a->{$map->[0]} <=> $b->{$map->[0]};
        }
        else {
          $res = $a->{$map->[0]} cmp $b->{$map->[0]};
        }
      }
      elsif ($field eq 'hasKeyword') {
        my $keyword = $arg->{keyword} // '';
        my $av = $a->{keywords}{$keyword} ? 1 : 0;
        my $bv = $b->{keywords}{$keyword} ? 1 : 0;
        $res = $av <=> $bv;
      }
      elsif ($field eq 'allInThreadHaveKeyword') {
        my $keyword = $arg->{keyword} // '';
        $storage->{hasthreadkeyword} ||= _hasthreadkeyword($storage->{data});
        my $av = ($storage->{hasthreadkeyword}{$a->{thrid}}{$keyword} || 0) == 2 ? 1 : 0;
        my $bv = ($storage->{hasthreadkeyword}{$b->{thrid}}{$keyword} || 0) == 2 ? 1 : 0;
        $res = $av <=> $bv;
      }
      elsif ($field eq 'someInThreadHaveKeyword') {
        my $keyword = $arg->{keyword} // '';
        $storage->{hasthreadkeyword} ||= _hasthreadkeyword($storage->{data});
        my $av = ($storage->{hasthreadkeyword}{$a->{thrid}}{$keyword} || 0) ? 1 : 0;
        my $bv = ($storage->{hasthreadkeyword}{$b->{thrid}}{$keyword} || 0) ? 1 : 0;
        $res = $av <=> $bv;
      }
      else {
        die "unknown field $field";
      }

      $res = -$res if defined($arg->{isAscending}) && !$arg->{isAscending};

      return $res if $res;
    }
    return $a->{msgid} cmp $b->{msgid}; # stable sort
  } @$data;

  return \@res;
}

sub _load_mailbox {
  my $Self = shift;
  my $id = shift;

  $Self->begin();
  my $data = $Self->{db}->dgetby('jmessagemap', 'msgid', { jmailboxid => $id }, 'msgid,jmodseq,active');
  $Self->commit();

  return $data;
}

sub _load_msgmap {
  my $Self = shift;
  my $id = shift;

  $Self->begin();
  my $data = $Self->{db}->dget('jmessagemap', {}, 'msgid,jmailboxid,jmodseq,active');
  $Self->commit();
  my %map;
  foreach my $row (@$data) {
    $map{$row->{msgid}}{$row->{jmailboxid}} = $row;
  }
  return \%map;
}

sub _load_hasatt {
  my $Self = shift;
  $Self->begin();
  my $data = $Self->{db}->dgetcol('jrawmessage', { hasAttachment => 1 }, 'msgid');
  $Self->commit();
  return { map { $_ => 1 } @$data };
}

sub _hasthreadkeyword {
  my $data = shift;
  my %res;
  foreach my $item (@$data) {
    next unless $item->{active};  # we get called by getEmailListUpdates, which includes inactive messages

    # have already seen a message for this thread
    if ($res{$item->{thrid}}) {
      foreach my $keyword (keys %{$item->{keywords}}) {
        # if not already known about, it wasn't present on previous messages, so it's a "some"
        $res{$item->{thrid}}{$keyword} ||= 1;
      }
      foreach my $keyword (keys %{$res{$item->{thrid}}}) {
        # if it was known already, but isn't on this one, it's a some
        $res{$item->{thrid}}{$keyword} = 1 unless $item->{keywords}{$keyword};
      }
    }

    # first message, it's "all" for every keyword
    else {
      $res{$item->{thrid}} = { map { $_ => 2 } keys %{$item->{keywords}} };
    }
  }
  return \%res;
}

sub _match {
  my $Self = shift;
  my ($item, $condition, $storage) = @_;

  return $Self->_match_operator($item, $condition, $storage) if $condition->{operator};

  if ($condition->{inMailbox}) {
    my $id = $Self->idmap($condition->{inMailbox});
    $storage->{mailbox}{$id} ||= $Self->_load_mailbox($id);
    return 0 unless $storage->{mailbox}{$id}{$item->{msgid}}{active};
  }

  if ($condition->{inMailboxOtherThan}) {
    $storage->{msgmap} ||= $Self->_load_msgmap();
    my $cond = $condition->{inMailboxOtherThan};
    $cond = [$cond] unless ref($cond) eq 'ARRAY';  # spec and possible change
    my %match = map { $Self->idmap($_) => 1 } @$cond;
    my $data = $storage->{msgmap}{$item->{msgid}} || {};
    my $inany = 0;
    foreach my $id (keys %$data) {
      next if $match{$id};
      next unless $data->{$id}{active};
      $inany = 1;
    }
    return 0 unless $inany;
  }

  if ($condition->{before}) {
    my $time = str2time($condition->{before});
    return 0 unless $item->{internaldate} < $time;
  }

  if ($condition->{after}) {
    my $time = str2time($condition->{after});
    return 0 unless $item->{internaldate} >= $time;
  }

  if ($condition->{minSize}) {
    return 0 unless $item->{msgsize} >= $condition->{minSize};
  }

  if ($condition->{maxSize}) {
    return 0 unless $item->{msgsize} < $condition->{maxSize};
  }

  # 2 == all
  # 1 == some
  # non-existent means none, of course
  if ($condition->{allInThreadHaveKeyword}) {
    # XXX case?
    $storage->{hasthreadkeyword} ||= _hasthreadkeyword($storage->{data});
    return 0 unless $storage->{hasthreadkeyword}{$item->{thrid}}{$condition->{allInThreadHaveKeyword}};
    return 0 unless $storage->{hasthreadkeyword}{$item->{thrid}}{$condition->{allInThreadHaveKeyword}} == 2;
  }

  if ($condition->{someInThreadHaveKeyword}) {
    # XXX case?
    $storage->{hasthreadkeyword} ||= _hasthreadkeyword($storage->{data});
    return 0 unless $storage->{hasthreadkeyword}{$item->{thrid}}{$condition->{someInThreadHaveKeyword}};
  }

  if ($condition->{noneInThreadHaveKeyword}) {
    $storage->{hasthreadkeyword} ||= _hasthreadkeyword($storage->{data});
    return 0 if $storage->{hasthreadkeyword}{$item->{thrid}}{$condition->{noneInThreadHaveKeyword}};
  }

  if ($condition->{hasKeyword}) {
    return 0 unless $item->{keywords}->{$condition->{hasKeyword}};
  }

  if ($condition->{notKeyword}) {
    return 0 if $item->{keywords}->{$condition->{notKeyword}};
  }

  if (exists $condition->{hasAttachment}) {
    $storage->{hasatt} ||= $Self->_load_hasatt();
    if ($condition->{hasAttachment}) {
      return 0 unless $storage->{hasatt}{$item->{msgid}};
    } else {
      return 0 if $storage->{hasatt}{$item->{msgid}};
    }
  }

  if ($condition->{text}) {
    $storage->{textsearch}{$condition->{text}} ||= $Self->{db}->imap_search('text', $condition->{text});
    return 0 unless $storage->{textsearch}{$condition->{text}}{$item->{msgid}};
  }

  if ($condition->{from}) {
    $storage->{fromsearch}{$condition->{from}} ||= $Self->{db}->imap_search('from', $condition->{from});
    return 0 unless $storage->{fromsearch}{$condition->{from}}{$item->{msgid}};
  }

  if ($condition->{to}) {
    $storage->{tosearch}{$condition->{to}} ||= $Self->{db}->imap_search('to', $condition->{to});
    return 0 unless $storage->{tosearch}{$condition->{to}}{$item->{msgid}};
  }

  if ($condition->{cc}) {
    $storage->{ccsearch}{$condition->{cc}} ||= $Self->{db}->imap_search('cc', $condition->{cc});
    return 0 unless $storage->{ccsearch}{$condition->{cc}}{$item->{msgid}};
  }

  if ($condition->{bcc}) {
    $storage->{bccsearch}{$condition->{bcc}} ||= $Self->{db}->imap_search('bcc', $condition->{bcc});
    return 0 unless $storage->{bccsearch}{$condition->{bcc}}{$item->{msgid}};
  }

  if ($condition->{subject}) {
    $storage->{subjectsearch}{$condition->{subject}} ||= $Self->{db}->imap_search('subject', $condition->{subject});
    return 0 unless $storage->{subjectsearch}{$condition->{subject}}{$item->{msgid}};
  }

  if ($condition->{body}) {
    $storage->{bodysearch}{$condition->{body}} ||= $Self->{db}->imap_search('body', $condition->{body});
    return 0 unless $storage->{bodysearch}{$condition->{body}}{$item->{msgid}};
  }

  if ($condition->{header}) {
    my $cond = $condition->{header};
    $cond->[1] = '' if @$cond == 1;
    my $storekey = join(',', @$cond);
    $storage->{headersearch}{$storekey} ||= $Self->{db}->imap_search('header', @$cond);
    return 0 unless $storage->{headersearch}{$storekey}{$item->{msgid}};
  }

  return 1;
}


sub _match_operator {
  my $Self = shift;
  my ($item, $filter, $storage) = @_;
  if ($filter->{operator} eq 'NOT') {
    return not $Self->_match_operator($item, {operator => 'OR', conditions => $filter->{conditions}}, $storage);
  }
  elsif ($filter->{operator} eq 'OR') {
    foreach my $condition (@{$filter->{conditions}}) {
      return 1 if $Self->_match($item, $condition, $storage);
    }
    return 0;
  }
  elsif ($filter->{operator} eq 'AND') {
    foreach my $condition (@{$filter->{conditions}}) {
      return 0 if not $Self->_match($item, $condition, $storage);
    }
    return 1;
  }
  die "Invalid operator $filter->{operator}";
}

sub _messages_filter {
  my $Self = shift;
  my ($data, $filter, $storage) = @_;
  return [ grep { $Self->_match($_, $filter, $storage) } @$data ];
}

sub _collapse_messages {
  my $Self = shift;
  my ($data) = @_;
  my @res;
  my %seen;
  foreach my $item (@$data) {
    next if $seen{$item->{thrid}};
    push @res, $item;
    $seen{$item->{thrid}} = 1;
  }
  return \@res;
}

sub _extract_terms {
  my $filter = shift;
  return () unless $filter;
  return map { _extract_terms($_) } @$filter if ref($filter) eq 'ARRAY';
  my @list;
  push @list, _extract_terms($filter->{conditions});
  push @list, $filter->{body} if $filter->{body};
  push @list, $filter->{text} if $filter->{text};
  push @list, $filter->{subject} if $filter->{subject};
  return @list;
}

sub api_SearchSnippet_get {
  my $Self = shift;
  my $args = shift;

  my $messages = $Self->api_Email_get({
    accountId => $args->{accountId},
    ids => $args->{emailIds},
    properties => ['subject', 'preview'],
  });

  return $messages unless $messages->[0] eq 'Email/get';
  $messages->[0] = 'SearchSnippet/get';
  delete $messages->[1]{state};
  $messages->[1]{filter} = $args->{filter};
  $messages->[1]{collapseThreads} = $args->{collapseThreads}, # work around client bug

  my @terms = _extract_terms($args->{filter});
  my $str = join("|", @terms);
  my $tag = 'mark';
  foreach my $item (@{$messages->[1]{list}}) {
    $item->{emailId} = delete $item->{id};
    my $text = delete $item->{preview};
    unless (@terms) {
      $item->{subject} = undef;
      $item->{preview} = undef;
      $item->{body} = undef;
      next;
    }
    my $subj = escape_html($item->{subject} // '');
    (my $subj_marked = $subj) =~ s{\b($str)\b}{<$tag>$1</$tag>}gsi;
    $item->{subject} = ($subj_marked ne $subj) ? $subj_marked : undef;
    $item->{preview} = undef;
    if ($text =~ m{(.{0,20}\b(?:$str)\b.*)}gsi) {
      my $p = substr($1, 0, 200);
      $p =~ s{^\s+}{}gs;
      $p =~ s{\s+$}{}gs;
      $p =~ s{[\r\n]+}{ -- }gs;
      $p =~ s{\s+}{ }gs;
      $p = escape_html($p);
      $p =~ s{\b($str)\b}{<$tag>$1</$tag>}gsi;
      $item->{preview} = $p;
    }
    $item->{body} = $item->{preview}; # work around client bug
  }

  return $messages;
}

sub api_Email_query {
  my $Self = shift;
  my $args = shift;

  my ($user, $accountid) = $Self->_api_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;

  my $newQueryState = "$user->{jstateEmail}";

  return $Self->_transError(['error', {type => 'invalidArguments', arguments => ['position', 'anchor']}])
    if (exists $args->{position} and exists $args->{anchor});
  return $Self->_transError(['error', {type => 'invalidArguments', arguments => ['anchor', 'anchorOffset']}])
    if (exists $args->{anchor} and not exists $args->{anchorOffset});
  return $Self->_transError(['error', {type => 'invalidArguments', arguments => ['anchor', 'anchorOffset']}])
    if (not exists $args->{anchor} and exists $args->{anchorOffset});

  my $start = $args->{position} || 0;
  return $Self->_transError(['error', {type => 'invalidArguments',  arguments => ['position']}]) if $start < 0;

  my %valid_sort = map { $_ => 1 } qw(
    id receivedAt sentAt size subject from to
    hasKeyword allInThreadHaveKeyword someInThreadHaveKeyword
  );
  for my $arg (@{$args->{sort} // []}) {
    return $Self->_transError(['error', {type => 'unsupportedSort', sort => $arg}])
      unless $valid_sort{$arg->{property} // ''};
  }

  my $data = $Self->{db}->dget('jmessages', { active => 1 });

  # commit before applying the filter, because it might call out for searches
  $Self->commit();

  map { $_->{keywords} = decode_json($_->{keywords} || {}) } @$data;
  my $storage = {data => $data};
  $data = $Self->_post_sort($data, $args->{sort}, $storage);
  $data = $Self->_messages_filter($data, $args->{filter}, $storage) if $args->{filter};
  $data = $Self->_collapse_messages($data) if $args->{collapseThreads};

  $Self->{db}->save_query('Email', {
    filter          => $args->{filter},
    sort            => $args->{sort},
    collapseThreads => $args->{collapseThreads} ? 1 : 0,
  }, $newQueryState, [map { $_->{msgid} } @$data]);

  if ($args->{anchor}) {
    # need to calculate the position
    for (0..$#$data) {
      next unless $data->[$_]{msgid} eq $args->{anchor};
      $start = $_ + $args->{anchorOffset};
      $start = 0 if $start < 0;
      goto gotit;
    }
    return $Self->_transError(['error', {type => 'anchorNotFound'}]);
  }

gotit:

  my $end = $args->{limit} ? $start + $args->{limit} - 1 : $#$data;
  $end = $#$data if $end > $#$data;

  my @result = map { $data->[$_]{msgid} } $start..$end;

  my @res;
  push @res, ['Email/query', {
    accountId => $accountid,
    filter => $args->{filter},
    sort => $args->{sort},
    collapseThreads => $args->{collapseThreads},
    queryState => $newQueryState,
    canCalculateChanges => $JSON::true,
    position => $start,
    total => scalar(@$data),
    ids => [map { "$_" } @result],
  }];

  return @res;
}

sub api_Email_queryChanges {
  my $Self = shift;
  my $args = shift;

  my ($user, $accountid) = $Self->_api_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;

  my $newQueryState = "$user->{jstateEmail}";

  return $Self->_transError(['error', {type => 'invalidArguments', arguments => ['sinceQueryState']}])
    if not $args->{sinceQueryState};
  return $Self->_transError(['error', {type => 'cannotCalculateChanges', newQueryState => $newQueryState}])
    if ($user->{jdeletedmodseq} and $args->{sinceQueryState} <= $user->{jdeletedmodseq});

  my $data = $Self->{db}->dget('jmessages', { active => 1 });

  $Self->commit();

  my $qparams = {
    filter          => $args->{filter},
    sort            => $args->{sort},
    collapseThreads => $args->{collapseThreads} ? 1 : 0,
  };
  my $old_ids = $Self->{db}->load_query('Email', $qparams, $args->{sinceQueryState});

  return $Self->_transError(['error', {type => 'cannotCalculateChanges', newQueryState => $newQueryState}])
    unless defined $old_ids;

  map { $_->{keywords} = decode_json($_->{keywords} || {}) } @$data;
  my $storage = { data => $data };
  $data = $Self->_post_sort($data, $args->{sort}, $storage);
  $data = $Self->_messages_filter($data, $args->{filter}, $storage) if $args->{filter};
  $data = $Self->_collapse_messages($data) if $args->{collapseThreads};

  my @new_ids = map { $_->{msgid} } @$data;
  my %new_idx;
  $new_idx{$new_ids[$_]} = $_ for 0..$#new_ids;

  my @removed = grep { !exists $new_idx{$_} } @$old_ids;
  my %old_set  = map { $_ => 1 } @$old_ids;
  my @added;
  for my $i (0..$#new_ids) {
    push @added, { id => "$new_ids[$i]", index => $i }
      unless exists $old_set{$new_ids[$i]};
  }

  if ($args->{maxChanges} and (@removed + @added) > $args->{maxChanges}) {
    return $Self->_transError(['error', {type => 'cannotCalculateChanges', newQueryState => $newQueryState}]);
  }

  $Self->{db}->save_query('Email', $qparams, $newQueryState, \@new_ids);

  return ['Email/queryChanges', {
    accountId       => $accountid,
    filter          => $args->{filter},
    sort            => $args->{sort},
    collapseThreads => $args->{collapseThreads},
    oldQueryState   => "$args->{sinceQueryState}",
    newQueryState   => $newQueryState,
    removed         => [map { "$_" } @removed],
    added           => \@added,
    total           => scalar(@new_ids),
  }];
}

sub api_Email_get {
  my $Self = shift;
  my $args = shift;

  my ($user, $accountid) = $Self->_api_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;

  my $newState = "$user->{jstateEmail}";

  return $Self->_transError(['error', {type => 'invalidArguments',  arguments => ['ids']}])
    unless $args->{ids};

  # RFC 8621 default properties for Email/get
  my @EMAIL_DEFAULT_PROPERTIES = qw(
    id blobId threadId mailboxIds keywords size receivedAt
    messageId inReplyTo references sender from to cc bcc replyTo
    subject sentAt hasAttachment preview bodyValues textBody htmlBody attachments
  );

  # If properties not specified, use defaults
  unless ($args->{properties}) {
    $args->{properties} = \@EMAIL_DEFAULT_PROPERTIES;
  }

  my %seenids;
  my %missingids;
  my @list;
  my $need_content = 0;
  foreach my $prop (qw(hasAttachment headers preview textBody htmlBody attachments bodyValues bodyStructure messageId inReplyTo references sender)) {
    $need_content = 1 if _prop_wanted($args, $prop);
  }
  $need_content = 1 if grep { m/^header:/ } @{$args->{properties}};
  my %msgidmap;
  foreach my $msgid (map { $Self->idmap($_) } @{$args->{ids}}) {
    next if $seenids{$msgid};
    $seenids{$msgid} = 1;
    my $data = $Self->{db}->dgetone('jmessages', { msgid => $msgid, active => 1 });
    unless ($data) {
      $missingids{$msgid} = 1;
      next;
    }

    $msgidmap{$msgid} = $data->{msgid};
    my $item = {
      id => "$msgid",
    };

    if (_prop_wanted($args, 'threadId')) {
      $item->{threadId} = "$data->{thrid}";
    }

    if (_prop_wanted($args, 'mailboxIds')) {
      my $ids = $Self->{db}->dgetcol('jmessagemap', { msgid => $msgid, active => 1 }, 'jmailboxid');
      $item->{mailboxIds} = {map { $_ => $JSON::true } @$ids};
    }

    if (_prop_wanted($args, 'inReplyToEmailId')) {
      $item->{inReplyToEmailId} = $data->{msginreplyto};
    }

    if (_prop_wanted($args, 'hasAttachment')) {
      $item->{hasAttachment} = $data->{hasAttachment} ? $JSON::true : $JSON::false;
    }

    if (_prop_wanted($args, 'keywords')) {
      $item->{keywords} = decode_json($data->{keywords});
    }

    foreach my $email (qw(to cc bcc from)) {
      if (_prop_wanted($args, $email)) {
        my $raw = $data->{"msg$email"};
        $item->{$email} = (defined $raw && $raw ne '') ? Data::JSEmail::asAddresses($raw) : undef;
      }
    }
    # replyTo and sender not stored in DB — handled in fill_messages block below

    if (_prop_wanted($args, 'subject')) {
      $item->{subject} = Encode::decode_utf8($data->{msgsubject});
    }

    if (_prop_wanted($args, 'sentAt')) {
      $item->{sentAt} = Data::JSEmail::isodate($data->{msgdate});
    }

    if (_prop_wanted($args, 'receivedAt')) {
      $item->{receivedAt} = Data::JSEmail::isodate($data->{internaldate});
    }

    if (_prop_wanted($args, 'size')) {
      $item->{size} = $data->{msgsize};
    }

    if (_prop_wanted($args, 'blobId')) {
      $item->{blobId} = "m-$msgid";
    }

    push @list, $item;
  }

  $Self->commit();

  # need to load messages from the server
  if ($need_content) {
    # RFC 8621 Section 4.2: default bodyProperties
    my $bodyProperties = $args->{bodyProperties} || [qw(partId blobId size name type charset disposition cid language location)];

    my $content = $Self->{db}->fill_messages(map { $_->{id} } @list);
    foreach my $item (@list) {
      my $data = $content->{$item->{id}};
      if (_prop_wanted($args, 'preview')) {
        $item->{preview} = $data->{preview};
      }
      # replyTo and sender come from parsed content, not DB envelope
      for my $email (qw(replyTo sender)) {
        if (_prop_wanted($args, $email)) {
          $item->{$email} = $data->{$email}; # already parsed by Data::JSEmail
        }
      }
      if (_prop_wanted($args, 'textBody')) {
        $item->{textBody} = _filterBodyParts($data->{textBody}, $bodyProperties);
      }
      if (_prop_wanted($args, 'htmlBody')) {
        $item->{htmlBody} = _filterBodyParts($data->{htmlBody}, $bodyProperties);
      }
      if (_prop_wanted($args, 'body')) {
        if ($data->{htmlBody}) {
          $item->{htmlBody} = $data->{htmlBody};
        }
        else {
          $item->{textBody} = $data->{textBody};
        }
      }
      if (exists $item->{textBody} and not $item->{textBody}) {
        $item->{textBody} = JMAP::DB::htmltotext($data->{htmlBody});
      }
      if (_prop_wanted($args, 'hasAttachment')) {
        $item->{hasAttachment} = $data->{hasAttachment} ? $JSON::true : $JSON::false;
      }
      if (_prop_wanted($args, 'headers')) {
        $item->{headers} = $data->{headers};
      }
      elsif ($args->{properties}) {
        my %wanted;
        foreach my $prop (@{$args->{properties}}) {
          next unless $prop =~ m/^header:([^:]+)(.*)/;
          my $headername = lc $1;
          my $rest = $2;

          # Validate suffix format: optional :as{Type} then optional :all
          if ($rest ne '' && $rest !~ /^(:(asText|asAddresses|asGroupedAddresses|asMessageIds|asDate|asURLs|asRaw))?(:(all))?$/) {
            return $Self->_transError(['error', { type => 'invalidArguments', arguments => [$prop] }]);
          }

          my @values = map { $_->{value} // $_->{Value} } grep { lc($_->{name} // $_->{Name} // '') eq $headername } @{$data->{headers}||[]};
          unless (@values) {
            # :all returns empty array, non-:all returns null
            $item->{$prop} = ($rest =~ /:all/) ? [] : undef;
            next;
          }
          if ($rest =~ s/:all$//) {
            if ($rest eq ':asText') {
              $item->{$prop} = [map { Data::JSEmail::asText($_) } @values ];
            }
            elsif ($rest eq ':asAddresses') {
              $item->{$prop} = [map { Data::JSEmail::asAddresses($_) } @values ];
            }
            elsif ($rest eq ':asGroupedAddresses') {
              $item->{$prop} = [map { Data::JSEmail::asGroupedAddresses($_) } @values ];
            }
            elsif ($rest eq ':asMessageIds') {
              $item->{$prop} = [map { Data::JSEmail::asMessageIds($_) } @values ];
            }
            elsif ($rest eq ':asDate') {
              $item->{$prop} = [map { Data::JSEmail::asDate($_) } @values ];
            }
            elsif ($rest eq ':asURLs') {
              $item->{$prop} = [map { Data::JSEmail::asURLs($_) } @values ];
            }
            else {  # :asRaw or nothing
              $item->{$prop} = \@values;
            }
          }
          else {
            if ($rest eq ':asText') {
              $item->{$prop} = Data::JSEmail::asText($values[-1]);
            }
            elsif ($rest eq ':asAddresses') {
              $item->{$prop} = Data::JSEmail::asAddresses($values[-1]);
            }
            elsif ($rest eq ':asGroupedAddresses') {
              $item->{$prop} = Data::JSEmail::asGroupedAddresses($values[-1]);
            }
            elsif ($rest eq ':asMessageIds') {
              $item->{$prop} = Data::JSEmail::asMessageIds($values[-1]);
            }
            elsif ($rest eq ':asDate') {
              $item->{$prop} = Data::JSEmail::asDate($values[-1]);
            }
            elsif ($rest eq ':asURLs') {
              $item->{$prop} = Data::JSEmail::asURLs($values[-1]);
            }
            else {  # :asRaw or nothing
              $item->{$prop} = $values[-1];
            }
          }
        }
      }
      if (_prop_wanted($args, 'attachments')) {
        $item->{attachments} = _filterBodyParts($data->{attachments}, $bodyProperties);
      }
      if (_prop_wanted($args, 'attachedEmails')) {
        $item->{attachedEmails} = $data->{attachedEmails};
      }
      if (_prop_wanted($args, 'bodyStructure')) {
        $item->{bodyStructure} = _filterBodyPart($data->{bodyStructure}, $bodyProperties);
      }

      # bodyValues: always present, but only populated when fetch*BodyValues flags are set
      if (_prop_wanted($args, 'bodyValues') && ($args->{fetchAllBodyValues} || $args->{fetchTextBodyValues} || $args->{fetchHTMLBodyValues})) {
        my %wantParts;
        if ($args->{fetchAllBodyValues}) {
          for my $part (@{$data->{textBody} || []}, @{$data->{htmlBody} || []}) {
            $wantParts{$part->{partId}} = 1 if $part->{partId};
          }
        }
        else {
          if ($args->{fetchTextBodyValues}) {
            for my $part (@{$data->{textBody} || []}) {
              $wantParts{$part->{partId}} = 1 if $part->{partId};
            }
          }
          if ($args->{fetchHTMLBodyValues}) {
            for my $part (@{$data->{htmlBody} || []}) {
              $wantParts{$part->{partId}} = 1 if $part->{partId};
            }
          }
        }

        my %bodyValues;
        my $maxBytes = $args->{maxBodyValueBytes};
        for my $partId (keys %wantParts) {
          my $bv = $data->{bodyValues}{$partId};
          next unless $bv;
          my %val = %$bv;
          if ($maxBytes && $maxBytes > 0 && defined $val{value}) {
            my $val_bytes = Encode::encode_utf8($val{value});
            if (length($val_bytes) > $maxBytes) {
              # Truncate, then remove any trailing partial UTF-8 char
              my $truncated = substr($val_bytes, 0, $maxBytes);
              # Strip trailing continuation bytes + incomplete lead byte
              while (length($truncated) && (ord(substr($truncated, -1)) & 0xC0) == 0x80) {
                chop $truncated;
              }
              # If last byte is a multi-byte lead that's now incomplete, remove it
              if (length($truncated) && ord(substr($truncated, -1)) >= 0xC0) {
                my $lead = ord(substr($truncated, -1));
                my $expected = ($lead < 0xE0) ? 2 : ($lead < 0xF0) ? 3 : 4;
                # Check if we have enough following bytes (we don't, we just stripped them)
                chop $truncated;
              }
              $val{value} = Encode::decode_utf8($truncated);
              $val{isTruncated} = $JSON::true;
            }
          }
          $bodyValues{$partId} = \%val;
        }
        $item->{bodyValues} = \%bodyValues;
      }
      elsif (_prop_wanted($args, 'bodyValues')) {
        $item->{bodyValues} = {};
      }
      if (_prop_wanted($args, 'messageId')) {
        $item->{messageId} = $data->{messageId};
      }
      if (_prop_wanted($args, 'references')) {
        $item->{references} = $data->{references};
      }
      if (_prop_wanted($args, 'inReplyTo')) {
        $item->{inReplyTo} = $data->{inReplyTo};
      }
    }
  }

  return ['Email/get', {
    list => \@list,
    accountId => $accountid,
    state => $newState,
    notFound => [map { "$_" } keys %missingids],
  }];
}

# NOT AN API CALL as such...
sub getRawBlob {
  my $Self = shift;
  my $selector = shift;

  return () unless $selector =~ m{([mf]-[^/]+)/(.*)};
  my $blobId = $1;
  my $filename = $2;

  my ($type, $data) = $Self->{db}->get_blob($blobId);

  return ($type, $data, $filename);
}

# or this
# Filter a single body part to only include requested properties
sub _filterBodyPart {
  my $data = shift;
  my $props = shift;
  return $data unless $props; # undef means no filtering
  my %res;
  my %want = map { $_ => 1 } @$props;
  for my $prop (@$props) {
    $res{$prop} = $data->{$prop} if exists $data->{$prop};
  }
  # subParts: array for multipart, null for leaf parts
  if ($want{subParts}) {
    if ($data->{subParts}) {
      $res{subParts} = [ map { _filterBodyPart($_, $props) } @{$data->{subParts}} ];
    } else {
      $res{subParts} = [];
    }
  }
  elsif ($data->{subParts}) {
    # Always include subParts structurally even if not explicitly requested
    $res{subParts} = [ map { _filterBodyPart($_, $props) } @{$data->{subParts}} ];
  }
  return \%res;
}

# Filter a list of body parts
sub _filterBodyParts {
  my $parts = shift;
  my $props = shift;
  return $parts unless $props; # undef means no filtering
  return [ map { _filterBodyPart($_, $props) } @{$parts || []} ];
}

# backward compat alias
sub createBodyStructure { _filterBodyPart(@_) }

# or this
sub uploadFile {
  my $Self = shift;
  my ($accountid, $type, $content) = @_; # XXX filehandle?

  return $Self->{db}->put_file($accountid, $type, $content);
}

sub downloadFile {
  my $Self = shift;
  my $jfileid = shift;

  my ($type, $content) = $Self->{db}->get_blob($jfileid);

  return ($type, $content);
}

sub api_Email_changes {
  my $Self = shift;
  my $args = shift;

  my ($user, $accountid) = $Self->_api_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;

  my $newState = "$user->{jstateEmail}";

  my @e = $Self->_check_since_state($args, $user, $newState);
  return @e if @e;

  my $data = $Self->{db}->dget('jmessages', { jmodseq => ['>', $args->{sinceState}] }, 'msgid,active,jcreated,jmodseq');

  my $partial;
  ($data, $partial) = $Self->_limit_changes($data, $args, \$newState);
  return $Self->_transError(['error', {type => 'cannotCalculateChanges', newState => $newState}]) unless defined $data;

  $Self->commit();

  my ($created, $updated, $destroyed) = $Self->_classify_changes($data, $args->{sinceState}, 'msgid');

  my @res;
  push @res, ['Email/changes', {
    accountId => $accountid,
    oldState => "$args->{sinceState}",
    newState => $newState,
    created => [map { "$_" } @$created],
    updated => [map { "$_" } @$updated],
    destroyed => [map { "$_" } @$destroyed],
    hasMoreChanges => $partial ? JSON::true : JSON::false,
  }];

  return @res;
}

sub api_Email_set {
  my $Self = shift;
  my $args = shift;

  $Self->begin();

  my $accountid = $Self->{db}->accountid();
  return $Self->_transError(['error', {type => 'accountNotFound'}])
    if ($args->{accountId} and $args->{accountId} ne $accountid);

  $Self->commit();

  my $create = $args->{create} || {};
  my $update = $args->{update} || {};
  my $destroy = $args->{destroy} || [];

  my ($created, $notCreated, $updated, $notUpdated, $destroyed, $notDestroyed);
  my ($oldState, $newState);

  my $scoped_lock = $Self->{db}->begin_superlock();

  # get state up-to-date first
  $Self->{db}->sync_imap();

  $Self->begin();
  my $user = $Self->{db}->get_user();
  $Self->commit();
  $oldState = "$user->{jstateEmail}";

  return $Self->_transError(['error', {type => 'stateMismatch', oldState => $oldState, newState => $oldState}])
    if defined $args->{ifInState} and $args->{ifInState} ne $oldState;

  ($created, $notCreated) = $Self->{db}->create_messages($create, sub { $Self->idmap(shift) });
  $Self->setid($_, $created->{$_}{id}) for keys %$created;
  $Self->_resolve_patch($update, 'api_Email_get');
  ($updated, $notUpdated) = $Self->{db}->update_messages($update, sub { $Self->idmap(shift) });
  ($destroyed, $notDestroyed) = $Self->{db}->destroy_messages($destroy);

  # XXX - cheap dumb racy version
  $Self->{db}->sync_imap();

  $Self->begin();
  $user = $Self->{db}->get_user();
  $Self->commit();
  $newState = "$user->{jstateEmail}";

  foreach my $cid (sort keys %$created) {
    my $msgid = $created->{$cid}{id};
    $created->{$cid}{blobId} = "m-$msgid";
  }

  my @res;
  push @res, ['Email/set', {
    accountId => $accountid,
    oldState => $oldState,
    newState => $newState,
    created => _nullempty($created),
    notCreated => _nullempty($notCreated),
    updated => _nullempty($updated),
    notUpdated => _nullempty($notUpdated),
    destroyed => _nullempty($destroyed),
    notDestroyed => _nullempty($notDestroyed),
  }];

  return @res;
}

sub api_Email_import {
  my $Self = shift;
  my $args = shift;

  my %created;
  my %notcreated;

  my ($oldState, $newState);

  my $scoped_lock = $Self->{db}->begin_superlock();

  # make sure our DB is up to date
  $Self->{db}->sync_folders();

  my ($user, $accountid) = $Self->_api_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;

  return $Self->_transError(['error', {type => 'invalidArguments', arguments => ['emails']}])
    if (not $args->{emails} or ref($args->{emails}) ne 'HASH');

  my $mailboxdata = $Self->{db}->dget('jmailboxes', { active => 1 });
  my %validids = map { $_->{jmailboxid} => 1 } @$mailboxdata;

  $Self->commit();
  $oldState = "$user->{jstateEmail}";

  return $Self->_transError(['error', {type => 'stateMismatch', oldState => $oldState, newState => $oldState}])
    if defined $args->{ifInState} and $args->{ifInState} ne $oldState;

  my %todo;
  foreach my $id (keys %{$args->{emails}}) {
    my $message = $args->{emails}{$id};
    my @ids;
    my @bad;

    my $date = $message->{receivedAt} ? str2time($message->{receivedAt}) : time();
    unless (defined $date) {
      push @bad, 'receivedAt';
    }

    if (exists $message->{keywords} and not _good_keywords($message->{keywords})) {
      push @bad, 'keywords';
    }

    if (not $message->{mailboxIds} or ref($message->{mailboxIds}) ne 'HASH') {
      push @bad, 'mailboxIds';
    }
    else {
      @ids = map { $Self->idmap($_) } keys %{$message->{mailboxIds}};
      if (grep { not $validids{$_} } @ids) {
        push @bad, 'mailboxIds';
      }
    }

    my ($type, $file);
    if (not defined $message->{blobId} or $message->{blobId} eq '') {
      push @bad, 'blobId';
    }
    else {
      ($type, $file) = $Self->{db}->get_blob($message->{blobId});
      unless ($file and $type eq 'message/rfc822') {
        push @bad, 'blobId';
      }
    }

    if (@bad) {
      $notcreated{$id} = { type => 'invalidProperties', properties => [sort @bad] };
      next;
    }

    my ($msgid, $thrid, $size) = eval { $Self->{db}->import_message($file, \@ids, $message->{keywords}, $date) };
    if ($@) {
      $notcreated{$id} = { type => 'internalError', description => $@ };
      next;
    }

    $created{$id} = {
      id => $msgid,
      blobId => $message->{blobId},
      threadId => $thrid,
      size => $size,
    };
  }

  $Self->{db}->sync_imap();

  $Self->begin();
  $user = $Self->{db}->get_user();
  $Self->commit();
  $newState = "$user->{jstateEmail}";

  my @res;
  push @res, ['Email/import', {
    accountId => $accountid,
    created => _nullempty(\%created),
    notCreated => _nullempty(\%notcreated),
    oldState => $oldState,
    newState => $newState,
  }];

  return @res;
}

sub _good_keywords {
  my $val = shift;
  return unless ref($val) eq 'HASH';
  # Strip null/false values (some clients send them for unset keywords)
  for my $key (keys %$val) {
    if (!$val->{$key} || !JSON::is_bool($val->{$key})) {
      delete $val->{$key};
      next;
    }
  }
  for my $key (keys %$val) {
    # bad characters
    return if $key =~ m/[\x00-\x20\(\)\{\}\%\*\"\\]/;
  }
  return 1;
}


sub api_Email_parse {
  my $Self = shift;
  my $args = shift;

  my ($user, $accountid) = $Self->_api_init($args);
  return $Self->_transError(['error', {type => 'accountNotFound'}]) unless defined $accountid;

  return $Self->_transError(['error', {type => 'invalidArguments', arguments => ['blobIds']}])
    unless $args->{blobIds} && ref($args->{blobIds}) eq 'ARRAY';

  # RFC 8621 §4.9 default properties for Email/parse
  my @PARSE_DEFAULT_PROPERTIES = qw(
    messageId inReplyTo references sender from to cc bcc replyTo
    subject sentAt hasAttachment preview bodyValues textBody htmlBody attachments
  );
  $args->{properties} //= \@PARSE_DEFAULT_PROPERTIES;

  my $bodyProperties = $args->{bodyProperties} || [qw(partId blobId size name type charset disposition cid language location)];

  # get_blob calls begin() internally; commit the _api_init transaction first
  $Self->commit();

  my %parsed;
  my @notParsable;
  my @notFound;

  for my $blobId (@{$args->{blobIds}}) {
    my ($type, $content) = $Self->{db}->get_blob($blobId);
    unless (defined $content && length $content) {
      push @notFound, $blobId;
      next;
    }

    my $data = eval { Data::JSEmail::parse($content, $blobId) };
    if ($@ || !$data) {
      push @notParsable, $blobId;
      next;
    }

    my %item;

    # These fields are always null for parsed (not stored) emails
    $item{id}         = undef if _prop_wanted($args, 'id');
    $item{blobId}     = $blobId if _prop_wanted($args, 'blobId');
    $item{threadId}   = undef if _prop_wanted($args, 'threadId');
    $item{mailboxIds} = undef if _prop_wanted($args, 'mailboxIds');
    $item{keywords}   = undef if _prop_wanted($args, 'keywords');
    $item{receivedAt} = undef if _prop_wanted($args, 'receivedAt');
    $item{size}       = undef if _prop_wanted($args, 'size');

    if (_prop_wanted($args, 'messageId')) {
      $item{messageId} = $data->{messageId};
    }
    if (_prop_wanted($args, 'inReplyTo')) {
      $item{inReplyTo} = $data->{inReplyTo};
    }
    if (_prop_wanted($args, 'references')) {
      $item{references} = $data->{references};
    }
    if (_prop_wanted($args, 'subject')) {
      $item{subject} = $data->{subject};
    }
    if (_prop_wanted($args, 'sentAt')) {
      $item{sentAt} = $data->{sentAt};
    }
    if (_prop_wanted($args, 'hasAttachment')) {
      $item{hasAttachment} = $data->{hasAttachment} ? $JSON::true : $JSON::false;
    }
    if (_prop_wanted($args, 'preview')) {
      $item{preview} = $data->{preview};
    }
    for my $addr (qw(from to cc bcc replyTo sender)) {
      if (_prop_wanted($args, $addr)) {
        $item{$addr} = $data->{$addr};
      }
    }
    if (_prop_wanted($args, 'headers')) {
      $item{headers} = $data->{headers};
    }
    elsif ($args->{properties}) {
      for my $prop (@{$args->{properties}}) {
        next unless $prop =~ m/^header:([^:]+)(.*)/;
        my $headername = lc $1;
        my $rest = $2;

        if ($rest ne '' && $rest !~ /^(:(asText|asAddresses|asGroupedAddresses|asMessageIds|asDate|asURLs|asRaw))?(:(all))?$/) {
          return $Self->_transError(['error', { type => 'invalidArguments', arguments => [$prop] }]);
        }

        my @values = map { $_->{value} // $_->{Value} } grep { lc($_->{name} // $_->{Name} // '') eq $headername } @{$data->{headers}||[]};
        unless (@values) {
          $item{$prop} = ($rest =~ /:all/) ? [] : undef;
          next;
        }
        if ($rest =~ s/:all$//) {
          if ($rest eq ':asText') { $item{$prop} = [map { Data::JSEmail::asText($_) } @values] }
          elsif ($rest eq ':asAddresses') { $item{$prop} = [map { Data::JSEmail::asAddresses($_) } @values] }
          elsif ($rest eq ':asGroupedAddresses') { $item{$prop} = [map { Data::JSEmail::asGroupedAddresses($_) } @values] }
          elsif ($rest eq ':asMessageIds') { $item{$prop} = [map { Data::JSEmail::asMessageIds($_) } @values] }
          elsif ($rest eq ':asDate') { $item{$prop} = [map { Data::JSEmail::asDate($_) } @values] }
          elsif ($rest eq ':asURLs') { $item{$prop} = [map { Data::JSEmail::asURLs($_) } @values] }
          else { $item{$prop} = \@values }
        }
        else {
          if ($rest eq ':asText') { $item{$prop} = Data::JSEmail::asText($values[-1]) }
          elsif ($rest eq ':asAddresses') { $item{$prop} = Data::JSEmail::asAddresses($values[-1]) }
          elsif ($rest eq ':asGroupedAddresses') { $item{$prop} = Data::JSEmail::asGroupedAddresses($values[-1]) }
          elsif ($rest eq ':asMessageIds') { $item{$prop} = Data::JSEmail::asMessageIds($values[-1]) }
          elsif ($rest eq ':asDate') { $item{$prop} = Data::JSEmail::asDate($values[-1]) }
          elsif ($rest eq ':asURLs') { $item{$prop} = Data::JSEmail::asURLs($values[-1]) }
          else { $item{$prop} = $values[-1] }
        }
      }
    }
    if (_prop_wanted($args, 'textBody')) {
      $item{textBody} = _filterBodyParts($data->{textBody}, $bodyProperties);
    }
    if (_prop_wanted($args, 'htmlBody')) {
      $item{htmlBody} = _filterBodyParts($data->{htmlBody}, $bodyProperties);
    }
    if (_prop_wanted($args, 'attachments')) {
      $item{attachments} = _filterBodyParts($data->{attachments}, $bodyProperties);
    }
    if (_prop_wanted($args, 'bodyStructure')) {
      $item{bodyStructure} = _filterBodyPart($data->{bodyStructure}, $bodyProperties);
    }
    if (_prop_wanted($args, 'bodyValues')) {
      if ($args->{fetchAllBodyValues} || $args->{fetchTextBodyValues} || $args->{fetchHTMLBodyValues}) {
        my %wantParts;
        if ($args->{fetchAllBodyValues}) {
          for my $part (@{$data->{textBody} || []}, @{$data->{htmlBody} || []}) {
            $wantParts{$part->{partId}} = 1 if $part->{partId};
          }
        }
        else {
          if ($args->{fetchTextBodyValues}) {
            $wantParts{$_->{partId}} = 1 for grep { $_->{partId} } @{$data->{textBody} || []};
          }
          if ($args->{fetchHTMLBodyValues}) {
            $wantParts{$_->{partId}} = 1 for grep { $_->{partId} } @{$data->{htmlBody} || []};
          }
        }
        my %bodyValues;
        my $maxBytes = $args->{maxBodyValueBytes};
        for my $partId (keys %wantParts) {
          my $bv = $data->{bodyValues}{$partId};
          next unless $bv;
          my %val = %$bv;
          if ($maxBytes && $maxBytes > 0 && defined $val{value}) {
            my $val_bytes = Encode::encode_utf8($val{value});
            if (length($val_bytes) > $maxBytes) {
              my $truncated = substr($val_bytes, 0, $maxBytes);
              while (length($truncated) && (ord(substr($truncated, -1)) & 0xC0) == 0x80) {
                chop $truncated;
              }
              if (length($truncated) && ord(substr($truncated, -1)) >= 0xC0) {
                chop $truncated;
              }
              $val{value} = Encode::decode_utf8($truncated);
              $val{isTruncated} = $JSON::true;
            }
          }
          $bodyValues{$partId} = \%val;
        }
        $item{bodyValues} = \%bodyValues;
      }
      else {
        $item{bodyValues} = {};
      }
    }

    $parsed{$blobId} = \%item;
  }

  return ['Email/parse', {
    accountId  => $accountid,
    parsed     => \%parsed,
    notParsable => \@notParsable,
    notFound   => \@notFound,
  }];
}

1;
