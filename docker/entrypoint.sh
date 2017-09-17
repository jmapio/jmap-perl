#! /bin/sh

# Find the docker IP
IP=`ip addr | awk '/inet 172/ { print $2 }' | cut -d'/' -f1`
# Replace all occurrence of "proxy.jmap.io" by the docker IP
sed -i "s?https://proxy.jmap.io?http://$IP?g" ./bin/server.pl ./htdocs/landing.html ./JMAP/API.pm ./JMAP/DB.pm
# Or can be occurrence of previous docker IP
sed -i "s?http://172[^/]*?http://$IP?g" ./bin/server.pl ./htdocs/landing.html ./JMAP/API.pm ./JMAP/DB.pm

export jmaphost=$IP

service nginx start
perl ./bin/server.pl &
perl ./bin/apiendpoint.pl
