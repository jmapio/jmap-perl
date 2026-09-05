FROM debian:bookworm-slim

LABEL org.opencontainers.image.source=https://github.com/jmapio/jmap-perl

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
    libcryptx-perl            \
    sqlite3                   \
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
    Crypt::JWT                      \
    && rm -rf /root/.cpanm

COPY . /opt/jmap-perl
WORKDIR /opt/jmap-perl

RUN mkdir -p /data

ENV JMAP_HOME=/opt/jmap-perl
ENV JMAP_DATADIR=/data
ENV JMAP_PORT=9000
ENV JMAP_MGMT_PORT=8080
ENV JMAP_MGMT_HOST=127.0.0.1

EXPOSE 9000 8080

# Liveness probe: a wedged or spinning event loop still holds the port open, so
# only an actual request distinguishes it from a healthy one.
# Note that Docker marks the container unhealthy but will NOT restart it --
# --restart acts on exit only. Restarting on unhealthy needs a supervisor.
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
  CMD perl -MHTTP::Tiny -e 'exit(HTTP::Tiny->new(timeout => 5)->get("http://127.0.0.1:$ENV{JMAP_MGMT_PORT}/healthz")->{success} ? 0 : 1)'

ENTRYPOINT ["/opt/jmap-perl/bin/docker-entrypoint.sh"]
