# TLS Proxy add-on

nginx as a TLS-terminating reverse proxy for Home Assistant: one HTTPS port for
everything, routed to internal backends by domain, using the certificate the
official Let's Encrypt add-on writes to `/ssl`. Optional high availability with
keepalived and a virtual IP.

- Routes by **HTTP `Host`**, so it also works behind another proxy that connects
  by IP address without SNI.
- Per-route certificate, plain-HTTP and TLS-to-backend settings.
- Dedicated-port passthrough (`mode: tcp`) for protocols that are not HTTP.
- IPv4 and IPv6, and an hourly check that reloads nginx after a renewal.

**[Full documentation: DOCS.md](DOCS.md)** — that is also what the add-on's
Documentation tab shows.

```
config.yaml                 add-on manifest: options schema, permissions
Dockerfile                  nginx alpine + keepalived
run.sh                      startup, certificate mirroring, renewal watch
generate-nginx-conf.sh      options -> nginx configuration
generate-keepalived-conf.sh options -> keepalived configuration
DOCS.md                     user-facing documentation
```
