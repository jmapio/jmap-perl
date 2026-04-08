FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential           \
    cpanminus                 \
    libanyevent-httpd-perl    \
    libdata-uuid-libuuid-perl \
    libdatetime-perl          \
    libdbd-sqlite3-perl       \
    libdbi-perl               \
    libemail-address-xs-perl  \
    libemail-mime-perl        \
    libhtml-parser-perl       \
    libhtml-strip-perl        \
    libhttp-date-perl         \
    libhttp-tiny-perl         \
    libimage-size-perl        \
    libio-socket-ssl-perl     \
    libencode-imaputf7-perl   \
    libjson-perl              \
    libjson-xs-perl           \
    libxml-parser-perl        \
    libnet-dns-perl           \
    libmodule-pluggable-perl  \
    libswitch-perl            \
    ca-certificates           \
    && rm -rf /var/lib/apt/lists/*

# CPAN modules not in Debian
RUN cpanm --notest \
    AnyEvent::HTTP                  \
    AnyEvent::HTTPD::CookiePatch    \
    AnyEvent::IMAP                  \
    Cookie::Baker                   \
    Date::Parse                     \
    Email::MIME::Header::AddressList \
    Email::Sender::Simple           \
    Email::Sender::Transport::SMTPS \
    HTML::GenerateUtil              \
    IO::LockedFile                  \
    Mail::IMAPTalk                  \
    Moose                           \
    Net::CalDAVTalk                 \
    Net::CardDAVTalk                \
    Net::DNS                        \
    Net::Server::Fork               \
    Template                        \
    MIME::Base64::URLSafe           \
    Data::JSEmail                   \
    Text::JSCalendar                \
    Text::JSContact                 \
    Data::UUID                      \
    URI                             \
    EV                              \
    && rm -rf /root/.cpanm

COPY . /opt/jmap-perl
WORKDIR /opt/jmap-perl

RUN mkdir -p /data

ENV JMAP_HOME=/opt/jmap-perl
ENV JMAP_DATADIR=/data
ENV JMAP_PORT=9000

EXPOSE 9000

ENTRYPOINT ["/opt/jmap-perl/bin/docker-entrypoint.sh"]
