Perl JMAP Proxy Server
======================

This is a simple implementation of a proxy server for the JMAP protocol as
specified at http://jmap.io/

At the backend, it talks to IMAP and SMTP servers to allow placing a JMAP
interface on top of a legacy mail system.

For efficiency reasons, this initial implementation requires that all servers
support the CONDSTORE extension, (RFC4551/RFC7162).

A separate backend for Gmail is provided, because Gmail has native server-side
thread support, meaning that threading does not need to be calculated locally.


Installation
------------

See the [INSTALL](./INSTALL) instructions in this repository.


Run in Docker
-------------

Build a Docker image from this repository using the included [Dockerfile](./Dockerfile):

```
docker build -t local/jmap-perl .
```

Run the JMAP Proxy Docker container:

```
docker run -p 8088:80 --name=jmap-proxy -d local/jmap-perl
```

Now connect to the running proxy via http://localhost:8088
