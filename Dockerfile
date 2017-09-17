FROM debian:jessie-slim

WORKDIR /root

RUN apt-get update
RUN apt-get -y install build-essential \
	libanyevent-httpd-perl \
	libdata-uuid-libuuid-perl \
	libdatetime-perl \
	libdbd-sqlite3-perl \
	libdbi-perl \
	libemail-address-perl \
	libemail-mime-perl \
	libhtml-parser-perl \
	libhtml-strip-perl \
	libhttp-date-perl \
	libhttp-tiny-perl \
	libimage-size-perl \
	libio-socket-ssl-perl \
	libencode-imaputf7-perl \
	libjson-perl \
	libjson-xs-perl \
	liblocale-gettext-perl \
	libswitch-perl \
	libexpat1-dev \
	libnet-libidn-perl \
	curl \
	git \
	nginx

RUN cpan; true

RUN perl -MCPAN -e 'my $c = "CPAN::HandleConfig"; $c->load(doit => 1, autoconfig => 1); $c->edit(prerequisites_policy => "follow"); $c->edit(build_requires_install_policy => "yes"); $c->commit'

RUN curl -L -O http://www.cpan.org/authors/id/C/CI/CINDY/AnyEvent-HTTPD-SendMultiHeaderPatch-0.001003.tar.gz && \
	tar xf AnyEvent-HTTPD-SendMultiHeaderPatch-0.001003.tar.gz && \
	cd AnyEvent-HTTPD-SendMultiHeaderPatch-0.001003 && \
	perl Makefile.PL && \
	make install

ENV PERLPACKAGES "Test::Requires Mouse AnyEvent::HTTP AnyEvent::HTTPD::CookiePatch AnyEvent::IMAP Cookie::Baker Date::Parse Email::Sender::Simple Email::Sender::Transport::SMTPS HTML::GenerateUtil IO::LockedFile Mail::IMAPTalk Moose Net::CalDAVTalk Net::CardDAVTalk Net::DNS Net::Server::Fork Template"

RUN for PACKAGE in $PERLPACKAGES; do cpan $PACKAGE; done

RUN adduser --quiet --disabled-login --gecos "JMAP" jmap || true
RUN install -o jmap -g jmap -m 755 -d /home/jmap/data
RUN mkdir -p /home/jmap/data

COPY . /home/jmap/jmap-perl

WORKDIR /home/jmap/jmap-perl

RUN rm /etc/nginx/sites-enabled/default

COPY docker/nginx.conf /etc/nginx/sites-enabled/

COPY docker/entrypoint.sh /root/

EXPOSE 80

CMD ["sh", "/root/entrypoint.sh"]
