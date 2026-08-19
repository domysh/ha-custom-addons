# TLS Proxy

nginx exposing your services on a single HTTPS port (and optionally a plain
HTTP port), routing to internal backends **by domain**. The certificate is the
one the official **Let's Encrypt** add-on writes into `/ssl`
([hassio-addons/addon-letsencrypt](https://github.com/hassio-addons/addon-letsencrypt)),
which you install and run separately. That add-on issues **one** certificate
with every requested name as a SAN (`domains` + `additional_domains`), by
default at `/ssl/fullchain.pem` and `/ssl/privkey.pem` — so before adding a
route here, make sure its domain was requested there.

## How the routing works

Each entry in `routes` is a `domain` (the name the client asks for) and a
`target` (`host:port` of the backend). A target can be:

- the container name of another add-on on Home Assistant's Docker network,
  e.g. `addon_a0d7b954_something:8080`;
- an address reachable from the host, e.g. `127.0.0.1:8123` for Home Assistant
  itself, or `127.0.0.1:8080` for a port published by a container running in
  the [Fedora Podman Shell](../fedora_podman) add-on.

```yaml
listen_port: 443
http_port: 80
cert_file: "fullchain.pem"
key_file: "privkey.pem"
default_target: ""
routes:
  - domain: "home.example.com"
    target: "127.0.0.1:8123"
    mode: "http"
    enable_http: true    # also reachable in the clear on http_port
    target_tls: false    # the backend (Home Assistant Core) speaks plain HTTP
  - domain: "app.example.com"
    target: "127.0.0.1:8080"
    mode: "http"
    enable_http: false
    target_tls: false
```

`http` routes (the default) terminate TLS on `listen_port` (443 by default) and
pick the backend from the request's **`Host` header**. That it is the Host and
not the SNI matters: the Host header is always there, so routing still works for
a client that connects to a bare IP address without sending SNI — typically
another reverse proxy in front of this one.

A `Host` matching no route gets `444` (connection closed with no response),
unless you set `default_target`, which everything unmatched is forwarded to.

Traffic between the proxy and the backend stays internal, so the backend does
not have to publish a port to the outside world. Once a service is behind the
proxy, stopping it from publishing its own port directly on the host is
optional but recommended.

### Non-HTTP services (`mode: tcp`)

For protocols that are not HTTP — SMTP, IMAP, anything else — set
`mode: "tcp"` and a **dedicated** `tcp_port`, the public port that service is
exposed on:

```yaml
  - domain: "smtp.example.com"     # here only a descriptive label
    target: "127.0.0.1:4650"
    mode: "tcp"
    tcp_port: 465                 # public port dedicated to this service
    target_tls: false             # true only if the proxy must be the TLS client
```

These routes get a port of their own and do not share 443: the port already
identifies the service, so no SNI is needed and TLS is not terminated by the
proxy. The bytes pass through untouched and the backend presents its own
certificate — which suits a backend that already reads the same `/ssl`
certificate itself. A `tcp` route without a `tcp_port` is ignored, with a
warning in the log.

Note that a service which already publishes the right port on the host does not
need a `tcp` route at all — it is reachable directly. These are for the case
where the public port and the backend's port differ, or where the backend is
only reachable internally.

### Certificates per route

`cert_file` and `key_file` at the top level (default `fullchain.pem` and
`privkey.pem`, the Let's Encrypt add-on's standard output) say which files
inside `/ssl` are used to serve TLS to clients. Any route may override them
with its own, if you want a different bundle on that route — a certificate you
put in `/ssl` by hand under another name, for example. Leave them empty to use
the global default.

### Backends that expect TLS (`target_tls`)

`target_tls: true` makes the proxy **connect to the backend over TLS** instead
of in the clear, for backends that only listen on HTTPS. The backend's
certificate is not verified: it is reached by container name or internal IP, not
by its public hostname, so there is nothing meaningful to verify against. Leave
it `false` (the default) for backends that speak plain HTTP on the given port,
which is most internal web services.

### Plain HTTP as well (`enable_http`)

A route with `enable_http: true` is also reachable in the clear on `http_port`
(80 by default), routed by HTTP `Host` — here nginx's `http` module handles the
virtual host natively, so several domains on that port are fine. It still
honours `target_tls`: if the backend wants TLS, the request is forwarded to it
over HTTPS anyway; only the client's leg is in the clear. A `Host` that is not
configured on `http_port` gets `444`. Leave `enable_http: false` for non-HTTP
services and wherever you want to force TLS on the client side.

### Behind another reverse proxy

This works even when the upstream proxy connects **by IP address** and sends no
SNI, because `http` routes select the backend from the `Host` header. All the
upstream proxy has to do is forward the original Host (in nginx:
`proxy_set_header Host $host;`) and have that value match a route's `domain`.

If it sends a Host matching no route, the request gets `444`; `default_target`
is the way to send everything unrecognised to one backend instead.

### Reading the logs

The HTTP log is the standard `combined` format and includes the requested Host
and URL. `tcp` routes log separately, as `<ip> [<date>] :<port> -> <backend>`.

The resolver used for backend names (other add-ons' containers) is fixed to the
Home Assistant Supervisor's internal DNS (`172.30.32.3`) and is not
configurable. Names are resolved at connection time, so a backend that restarts
with a new IP address does not need the proxy restarted too.

## IPv4 and IPv6

Every listener binds on IPv4 and, with `enable_ipv6: true` (the default), on
IPv6 as well — `listen [::]:<port>`, a separate socket, no IPv4-mapped
addresses. The add-on runs with host networking, so this needs nothing more
than an IPv6 address on the host. If your host or network has no IPv6, set
`enable_ipv6: false`, or nginx fails to start when it cannot bind `[::]`.

## Certificate renewals

`/ssl` is re-checked every hour: when the Let's Encrypt add-on has renewed the
files, nginx is reloaded automatically, without dropping open connections.

A note on permissions: `/ssl/privkey.pem` is owned by root and not readable by
anyone else, while nginx drops privileges to the `nginx` user, and paths that
come from variables are opened lazily by the unprivileged worker rather than at
startup by the master. The add-on therefore keeps a copy in `/etc/nginx/certs`
owned by `nginx` with mode `400`, rewritten at every start and whenever a
renewal is detected. `/ssl` itself stays mounted read-only and is never
modified.

## High availability (keepalived + a virtual IP)

Install this add-on on **two or more** Home Assistant instances on the same L2
network, with the same options, and set `ha.enabled`. The proxies then
coordinate over VRRP and exactly one of them holds the virtual IP
(`ha.virtual_ip`) on its interface (`ha.interface`). If the active node loses
power or network, another takes the address over in about a second.

```yaml
ha:
  enabled: true
  interface: "eth0"
  virtual_ip: "192.168.1.250/24"
  virtual_router_id: 51    # must be identical on every node of the group
  priority: 150            # higher wins the election
  auth_pass: "a-shared-password"
```

- `virtual_router_id` must be **identical** across the group, and different
  from any other VRRP cluster on the same network. `auth_pass` likewise.
- `priority` must differ per node (150 on the primary, 100 on the secondary,
  say): it decides who holds the address under normal conditions.
- This needs `host_network: true` (already set in `config.yaml`): VRRP uses IP
  multicast and has to add and remove the virtual address on the host's real
  interface, which is also why the add-on asks for `NET_ADMIN` and `NET_RAW`
  and does not use Docker's bridge network.
- Point your clients — DNS records — at the virtual IP, not at an individual
  host.

With `ha.enabled: false` the add-on simply serves on `listen_port` on its own
host.

## Options reference

| Option | Type | Default | Meaning |
|---|---|---|---|
| `listen_port` | port | `443` | HTTPS port for all `http` routes. |
| `http_port` | port | `80` | Plain HTTP port, used by routes with `enable_http`. |
| `enable_ipv6` | bool | `true` | Also listen on `[::]`. Turn off on hosts without IPv6. |
| `cert_file` | str | `fullchain.pem` | Certificate in `/ssl` served to clients. |
| `key_file` | str | `privkey.pem` | Its private key. |
| `default_target` | str | *(empty)* | Where unmatched Hosts go; empty means `444`. |
| `routes[].domain` | str | — | The name the client asks for (a label only, for `tcp`). |
| `routes[].target` | str | — | `host:port` of the backend. |
| `routes[].mode` | `http`/`tcp` | `http` | Terminate TLS and route by Host, or pass a dedicated port through. |
| `routes[].tcp_port` | port | — | Required for `tcp`: the public port for this service. |
| `routes[].cert_file` / `key_file` | str | *(global)* | Per-route certificate override. |
| `routes[].enable_http` | bool | `false` | Also serve this route in the clear on `http_port`. |
| `routes[].target_tls` | bool | `false` | Connect to the backend over HTTPS. |
| `ha.*` | | | keepalived, see above. |
