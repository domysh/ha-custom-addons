# Changelog

## 1.0.0

First public release.

- nginx as a TLS-terminating reverse proxy, on `nginx:alpine` for `aarch64` and
  `amd64`, built on the target machine.
- Routes by the HTTP `Host` header rather than by SNI, so a client that
  connects to a bare IP address — another reverse proxy in front of this one,
  typically — still reaches the right backend. An unmatched Host gets `444`, or
  `default_target` if one is set.
- Certificates are read from `/ssl`, where the official Let's Encrypt add-on
  writes them, with per-route overrides for serving a different bundle on a
  given route. `/ssl` is mounted read-only and never modified.
- `/ssl` is re-checked hourly and nginx reloaded after a renewal, without
  dropping open connections. The certificates are mirrored to an
  nginx-owned directory with mode `400`, because paths that come from
  variables are opened lazily by the unprivileged worker rather than at
  start-up by the master.
- Backends may be plain HTTP or HTTPS per route (`target_tls`), and a route can
  additionally be served in the clear on a separate HTTP port
  (`enable_http`).
- Non-HTTP protocols are passed through on a dedicated port per route
  (`mode: tcp`): TLS is not terminated, the backend presents its own
  certificate and sees the client's real address.
- IPv4 and IPv6 listeners, with IPv6 switchable off for hosts without it.
- Backend names are resolved through the Supervisor's DNS at connection time,
  so a backend that restarts with a new address does not need the proxy
  restarted.
- Optional high availability with keepalived: two or more instances on the same
  L2 network hold one virtual IP between them over VRRP, and the survivor takes
  it over in about a second.
