DOMAIN=jmap-proxy.local
DHPARAMDIR=/etc/ssl/dhparam/
DHPARAM=$(DOMAIN).dhparam
PRIVATEKEY=$(DOMAIN).privatekey
PUBLICCERT=$(DOMAIN).publiccert

PACKAGES=                   \
  build-essential           \
  cpanminus                 \
  libanyevent-httpd-perl    \
  libdata-uuid-libuuid-perl \
  libdatetime-perl          \
  libdbd-sqlite3-perl       \
  libdbi-perl               \
  libemail-address-xs-perl  \
  libemail-mime-perl        \
  libmodule-pluggable-perl  \
  libhtml-parser-perl       \
  libhtml-strip-perl        \
  libhttp-date-perl         \
  libhttp-tiny-perl         \
  libimage-size-perl        \
  libio-socket-ssl-perl     \
  libencode-imaputf7-perl   \
  libjson-perl              \
  libxml-parser-perl        \
  libtest-xml-perl          \
  libnet-dns-perl           \
  libjson-xs-perl           \
  liblocale-gettext-perl    \
  libswitch-perl            \
  nginx                     \

PERLPACKAGES=                     \
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
  Test::Requires                  \

all: $(DHPARAM) $(PUBLICCERT)

$(DHPARAM):
	openssl dhparam -outform pem -out $(DHPARAM) 2048

$(PUBLICCERT) : $(PRIVATEKEY)
	openssl req -key $(PRIVATEKEY) -new -nodes -out $@ -days 365 -x509 -subj '/C=AU/ST=Victoria/L=Melbourne/O=$(DOMAIN)/OU=testing/CN=*.$(DOMAIN)'

$(PRIVATEKEY):
	openssl genrsa -out $@ 2048;

install: all
	apt-get install -y $(PACKAGES)
	$(foreach PERLPACKAGE, $(PERLPACKAGES), yes | cpanm $(PERLPACKAGE) &&) true
	install -o root -g root -m 755 -d $(DHPARAMDIR)
	install -o root -g root -m 644 $(DHPARAM) $(DHPARAMDIR)/$(DHPARAM)
	install -o root -g root -m 644 $(PUBLICCERT) /etc/ssl/certs/$(PUBLICCERT)
	install -o root -g root -m 644 $(PRIVATEKEY) /etc/ssl/private/$(PRIVATEKEY)
	install -o root -g root -m 644 nginx.conf /etc/nginx/sites-available/$(DOMAIN).conf
	ln -fs /etc/nginx/sites-available/$(DOMAIN).conf /etc/nginx/sites-enabled/$(DOMAIN).conf
	/etc/init.d/nginx restart
	adduser --quiet --disabled-login --gecos "JMAP" jmap || true
	if [ ! -d /home/jmap/jmap-perl ]; then \
	  git clone . /home/jmap/jmap-perl;    \
	fi
	install -o jmap -g jmap -m 755 -d /home/jmap/data
	if [ ! -d /home/jmap/jmap-perl/htdocs/client ]; then                                                 \
	  git clone https://github.com/jmapio/jmap-demo-webmail.git /home/jmap/jmap-perl/htdocs/client;      \
	  perl -pi -e 's/^/<!--/, s/$$/-->/ if /fixtures.js/' /home/jmap/jmap-perl/htdocs/client/index.html; \
	fi
	if [ ! -d /home/jmap/jmap-perl/htdocs/tmail ]; then                                                  \
	  git clone https://github.com/linagora/tmail-flutter /home/jmap/jmap-perl/htdocs/tmail;             \
	fi


diff: all
	diff -Nu /etc/nginx/sites-enabled/$(DOMAIN).conf nginx.conf || true
	diff -Nu /etc/ssl/certs/$(PUBLICCERT) $(PUBLICCERT)         || true
	diff -Nu /etc/ssl/private/$(PRIVATEKEY) $(PRIVATEKEY)       || true

clean:
	rm -f $(DHPARAM) $(PUBLICCERT) $(PRIVATEKEY)
