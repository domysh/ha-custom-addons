# Nginx UI

nginx, plus [Nginx UI](https://github.com/0xJacky/nginx-ui) — a web panel that
edits nginx's configuration for you: sites and streams, TLS certificates from
Let's Encrypt, log search, a config editor with syntax checking, and a terminal.

The add-on is a thin wrapper around upstream's official image. It gives it the
three things it cannot arrange for itself on Home Assistant OS — a place in the
boot order, Home Assistant's own directories, and storage that survives an
update — and then stays out of the way. **Everything else is configured from
the panel, not from the add-on options.** There are six of them: five describe
how to reach the panel, and the sixth is keepalived.

## First start

1. Install and start the add-on. Its log ends with the panel's address.
2. Open **Open Web UI**, or browse to `http://<home-assistant>:9000`.
3. Upstream's installation wizard asks for an administrator account and a
   language. That account is stored in the add-on's own database, separately
   from Home Assistant's users — this panel has no Home Assistant login.
4. From there on, work in the panel.

Port `9000` is the panel. Ports `80` and `443` are nginx itself, serving
whatever sites you create — **they must be free on the host before you start
the add-on**. If another add-on already holds them (the old TLS Proxy add-on
did), stop that one first.

## Options

```yaml
admin_port: 9000
admin_host: "0.0.0.0"
ssl: false
certfile: "fullchain.pem"
keyfile: "privkey.pem"
ha:
  enabled: false
  interface: "eth0"
  virtual_ip: ""
  virtual_router_id: 51
  priority: 100
  auth_pass: "changeme"
```

### `admin_port`

The port the panel listens on. `9000` by default, which is upstream's default
too.

This is an add-on option rather than a panel setting on purpose: it is the one
value that, set wrongly from inside the panel, would leave you with no way back
in. The add-on passes it to Nginx UI as an environment variable, which
overrides whatever is saved in `app.ini`, and the corresponding fields show as
read-only in the panel's own settings page.

Note that the **Open Web UI** button always points at `9000` — Home Assistant
resolves that from the add-on's manifest, which cannot see your options. If you
move the panel, browse to the new port directly.

### `admin_host`

The address the panel binds to. `0.0.0.0` means every interface on the host.

Because the add-on runs on the host's network, this is a real restriction and
not a formality: set it to a single LAN address to keep the panel off every
other interface, or to `127.0.0.1` to make it reachable only from the machine
itself (through a tunnel, or through an nginx site you have configured to
proxy it).

### `ssl`, `certfile`, `keyfile`

TLS for the panel itself — not for the sites nginx serves, which get their
certificates from the panel.

With `ssl: true`, the panel is served over HTTPS using `/ssl/<certfile>` and
`/ssl/<keyfile>`; the defaults are the names the official **Let's Encrypt**
add-on writes. `/ssl` is Home Assistant's own certificate directory, mapped
into this add-on.

If either file cannot be read, the add-on logs that and serves the panel over
plain HTTP rather than refusing to start: the panel is where a wrong filename
gets corrected, so it stays reachable.

### `ha.*` — high availability

Unchanged from the TLS Proxy add-on this one grew out of, and off by default.

With `ha.enabled: true` the add-on also runs **keepalived**, which gives a
group of machines one shared virtual IP address. The node with the highest
`priority` holds the address; if it stops answering, another takes it over
within a few seconds. Point your router's port forwarding, or your internal
DNS, at the virtual IP rather than at any one machine.

| Option | Meaning |
|---|---|
| `enabled` | Whether keepalived runs at all. |
| `interface` | The host interface the virtual IP is added to — `eth0`, `enp1s0`, `end0`. Check it in **Settings → System → Network**, or with `ip addr` on the host. |
| `virtual_ip` | The shared address, in CIDR form if the prefix is not `/32`, e.g. `192.168.1.10/24`. It must be free, on the same subnet as the interface, and outside your DHCP pool. |
| `virtual_router_id` | 1–255. The same number on every node of one group, and different from any other VRRP group on the network. |
| `priority` | 1–254. Highest wins. Give the machine you would rather serve from the higher number, e.g. 150 and 100. |
| `auth_pass` | A shared secret, the same on every node. VRRP's authentication is weak by design — it stops a misconfigured neighbour from joining, not an attacker. |

Every node needs the same `virtual_ip`, `virtual_router_id` and `auth_pass`,
and its own `priority`. Nothing else about the nodes has to match, but a
failover is only useful if the sites are configured the same way on both — the
panel's **Environments** feature can synchronise configuration between nodes.

If `virtual_ip` is empty while `ha.enabled` is true, the add-on logs the
problem and starts without keepalived. The panel keeps running: an add-on that
refused to start would take with it the only place the mistake can be fixed.

## Where everything is kept

Two directories hold state, and both live in the add-on's persistent `/data`:

| In the container | On disk | What is in it |
|---|---|---|
| `/etc/nginx` | `/data/nginx` | nginx's own configuration: `nginx.conf`, `conf.d`, `sites-available`, `sites-enabled`, `streams-available`, `streams-enabled`. |
| `/etc/nginx-ui` | `/data/nginx-ui` | Nginx UI's database (users, certificates, settings history) and its `app.ini`. |

Upstream's image expects these to be volumes; here they are symbolic links into
`/data`, which is the directory the Supervisor keeps across a restart, an
update and a rebuild. On the first start `/data/nginx` is empty, and upstream's
own initialisation seeds it with its template configuration — the one with the
`sites-*` and `streams-*` directories the panel manages.

A Home Assistant **backup** of this add-on contains `/data`, so it contains
every site, stream and certificate the panel manages, along with its database.
That is also the reason to keep the panel's own certificates in `/ssl` rather
than somewhere else if Home Assistant Core is to use them as well.

`/share` is mapped read-write, for static files you want to serve and for
anything else that should be visible to the rest of Home Assistant.

Logs (`/var/log/nginx`) are **not** persisted. The panel's log viewer and its
analytics therefore start empty after a restart. Persisting them would put an
unbounded, unrotated write load on Home Assistant's data partition, which is a
worse failure than losing yesterday's access log; if you want them kept, send
them to a file under `/share` from the site's configuration.

## Updates

The add-on pins an exact upstream image tag, and a workflow in this repository
checks daily whether a newer release exists. When one does, the pin and the
add-on's version move together and Home Assistant offers the update in the
usual place. The add-on's version *is* the upstream version: `2.5.10` here is
`uozi/nginx-ui:2.5.10`.

**Do not use the panel's own upgrade page.** In its official image, Nginx UI
updates itself by replacing its container through the Docker socket; that
socket is deliberately not mapped here, so the panel would instead replace its
own binary inside a container that Home Assistant rebuilds from the pinned tag
— the change would survive until the next restart and no longer. The add-on
sets upstream's `NGINX_UI_IGNORE_DOCKER_SOCKET`, which is upstream's documented
way of saying "this deployment is updated from outside", and which also stops
its self-check from reporting the missing socket as a fault.

## Putting Home Assistant behind it

The most common reason to run this is to publish Home Assistant Core itself
over HTTPS. In the panel: **Sites → Add site**, then a configuration along
these lines.

```nginx
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name home.example.com;

    ssl_certificate     /ssl/fullchain.pem;
    ssl_certificate_key /ssl/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8123;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        # Home Assistant's frontend is a WebSocket application; without these
        # two the page loads and then never updates.
        proxy_set_header Upgrade           $http_upgrade;
        proxy_set_header Connection        "upgrade";
    }
}
```

`127.0.0.1:8123` reaches Core because the add-on is on the host's network.

Home Assistant refuses proxied requests unless it is told to trust the proxy.
In `configuration.yaml`:

```yaml
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 127.0.0.1
    - ::1
```

If the certificate comes from the official Let's Encrypt add-on, it is at
`/ssl/fullchain.pem` as above. If you would rather have Nginx UI obtain it,
use the panel's **Certificates** page; it can write the result into `/ssl` too,
so Home Assistant Core can be pointed at the same files.

Certificates issued by the panel over the HTTP challenge need port `80`
reachable from the internet. The panel's own challenge port setting (`9180` by
default) is on its **Settings → Certificate** page, together with the account
e-mail and the renewal interval.

## Migrating from the TLS Proxy add-on

This add-on replaces TLS Proxy, and does not carry anything over from it: its
routes lived in the add-on options, and there is no meaningful way to translate
an options schema into a set of nginx sites without guessing at what was meant.
The two also cannot run at the same time, because both want ports 80 and 443.

1. Copy your `routes` out of the old add-on's configuration page.
2. Stop and uninstall TLS Proxy.
3. Install and start this add-on, and finish the installation wizard.
4. Recreate each route as a site in the panel. A `mode: http` route becomes a
   `server` block like the one above; a `mode: tcp` route becomes a **stream**;
   `mode: grpc` becomes a `grpc_pass` location; `websockets` becomes the two
   `Upgrade`/`Connection` headers, which are needed per location rather than
   per site.
5. `ha.*` transfers unchanged — the options mean exactly what they did.

The upside of the move is everything the old options schema could not express:
per-location settings, rate limits, caching, redirects, custom error pages,
access lists, `stream` blocks with their own TLS, and every other nginx
directive, without a new add-on option for each.

## Security

The panel is a root shell in all but name: it edits nginx's configuration, it
has a terminal, and it runs on the host's network. Treat it as you would treat
SSH access to the machine.

- Do not publish port `9000` to the internet. If it must be reachable from
  outside, put it behind a site of its own with TLS and access control, and
  bind the panel itself to `127.0.0.1` with `admin_host`.
- Use a real password for the administrator account, and turn on two-factor
  authentication in the panel — it supports TOTP and passkeys.
- The add-on runs with `NET_ADMIN` and `NET_RAW`, which keepalived needs to
  claim the virtual IP and to send VRRP. They are granted whether or not
  `ha.enabled` is set, because an add-on's capabilities are fixed in its
  manifest.

## Troubleshooting

**The add-on stops immediately, log mentions `bind() to 0.0.0.0:80 failed`.**
Something else on the host has port 80 or 443 — often the old TLS Proxy add-on,
or another reverse proxy add-on. Only one process can hold a port.

**The panel does not answer on 9000.** Check the add-on log for the
`panel on …` line, which prints the address actually in use. If `admin_host` is
not `0.0.0.0`, the panel is only on that address.

**"Nginx is not running" in the panel.** nginx exits when its configuration is
invalid, and a site saved with a syntax error is the usual cause. The add-on
log has nginx's own message; the panel's config editor will also point at the
line. s6 restarts nginx as soon as the configuration parses again.

**A certificate renewed by the Let's Encrypt add-on is not picked up.** nginx
reads certificate files at start-up and on reload; the panel's **Reload** does
that. Unlike the TLS Proxy add-on, nothing here watches `/ssl` for changes —
certificates issued by the panel itself are reloaded by the panel.

**Something in the panel is broken after an update.** The add-on is upstream's
image with three files added; almost everything is upstream's own behaviour.
Its documentation is at [nginxui.com](https://nginxui.com), and its issue
tracker at [0xJacky/nginx-ui](https://github.com/0xJacky/nginx-ui/issues). The
add-on's version is the upstream version, which is what to quote there.

## What runs inside

```
s6-overlay (PID 1, from upstream's image)
├── init-addon    this add-on: /data symlinks, options → environment,
│                 keepalived.conf
├── init-config   upstream: seeds /etc/nginx on first start
├── nginx         upstream: the web server, ports 80/443 and whatever your
│                 sites add
├── nginx-ui      upstream: the panel, on admin_port
└── keepalived    this add-on: the virtual IP, idle unless ha.enabled
```
