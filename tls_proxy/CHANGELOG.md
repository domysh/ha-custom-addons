# Changelog

## 1.2.0

- New per-route `grpc_paths`: path prefixes on an otherwise ordinary route that
  are proxied as gRPC. A backend fronting several services commonly serves HTTP
  and gRPC on one hostname, separated by path — a gRPC method is a path — and
  `mode: grpc` could only be applied to a whole route. nginx matches the
  longest prefix, so the two kinds of location coexist without ordering rules.
- New per-route `backend_http2`, which proxies to the backend over HTTP/2
  instead of HTTP/1.1. Off by default and per route: without TLS this is h2c
  with prior knowledge, which a backend that speaks only HTTP/1.1 refuses
  outright, and HTTP/2 has no `Upgrade` mechanism, so the websocket headers are
  correctly omitted from such a route. Support is probed with `nginx -V`, and a
  build that cannot do it falls back to HTTP/1.1 with a note in the log rather
  than failing to start.

## 1.1.0

- HTTP/2 on every HTTPS route, negotiated over ALPN so older clients are
  unaffected. New `enable_http2` option, on by default.
- HTTP/3 over QUIC on UDP `listen_port`, advertised per route with an `Alt-Svc`
  header — without which clients never attempt it. New `enable_http3` option,
  on by default. Support is probed with `nginx -V` at start-up rather than
  assumed: a `listen ... quic` directive in a binary without QUIC is a start-up
  failure, and this add-on is what everything else is published through, so a
  build without it logs the fact and serves HTTP/1.1 and HTTP/2 instead. Note
  that HTTP/3 needs UDP open on the router as well as TCP.
- New route mode `grpc`, proxying with nginx's gRPC module. gRPC is HTTP/2 end
  to end and carries its status in trailers, which an ordinary route drops on
  the way to an HTTP/1.1 backend — calls then fail in ways that look like the
  application's fault. Backend addresses stay resolvable at request time, and
  the timeouts allow a streaming RPC to idle between messages.

## 1.0.2

- Stop quickly, instead of waiting and then being killed. Shutdown asked nginx
  to quit gracefully, which waits for every request in flight — and a backend
  that is down keeps requests in flight for as long as their timeouts allow, so
  with clients retrying against one the wait never ended. The Supervisor allows
  ten seconds before SIGKILL, and that kill is what was reported as a failure.
  nginx is now told to shut down fast, anything still alive after three seconds
  is killed, and the add-on exits cleanly well inside the window.

## 1.0.1

- Report a clean shutdown as a clean shutdown. The entrypoint is PID 1, and its
  final `wait -n` returns the exit status of whichever process ended — which
  `set -e` then made the script's own status, so stopping the add-on was logged
  as a failure. nginx is now asked to quit gracefully, finishing the requests
  in flight, before anything is killed.
- Stop one unreachable backend from taking down every other route. nginx's
  default `proxy_connect_timeout` is 60 seconds and `worker_connections` was at
  its default 1024, so requests queuing for a dead backend held worker slots
  long enough to refuse connections on all domains — a single broken service
  presenting as a total outage. Connections to a backend now fail after 5
  seconds, on HTTP and TCP routes alike, and the worker limits are raised.
  The long read and send timeouts are unchanged: they apply only after a
  backend has accepted the connection, and are what keeps websockets and
  long-poll requests alive.

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
