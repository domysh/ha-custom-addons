# Changelog

The version number is upstream's: `2.5.10` is
[`uozi/nginx-ui:2.5.10`](https://github.com/0xJacky/nginx-ui/releases). Entries
here describe the add-on around it, not upstream's own release notes.

## 2.5.10

The TLS Proxy add-on became this one. It is a different add-on with a different
slug (`nginx_ui`), installed alongside the old one rather than as an update to
it, and nothing carries over automatically — see "Migrating from the TLS Proxy
add-on" in DOCS.md.

What changed, and why:

- **nginx is configured from a web panel, not from add-on options.** The old
  add-on translated a `routes` list into an nginx configuration, and every
  feature nginx has needed a new option, a new schema entry and new generator
  code before it could be used: HTTP/2, HTTP/3, gRPC, per-route certificates,
  WebSockets and TCP passthrough all arrived that way, and per-location
  settings, rate limits, caching and redirects never did. Nginx UI removes the
  translation layer instead of extending it.
- **The options that remain describe how to reach the panel** — `admin_port`,
  `admin_host`, `ssl`, `certfile`, `keyfile` — plus `ha.*`. The listening
  address stays an add-on option because it is the one setting that, wrong,
  locks you out of the panel that would fix it; it is passed to Nginx UI as an
  environment variable, which is what makes those fields read-only in the
  panel.
- **keepalived is unchanged**, down to the options and their meanings. It is
  now a supervised service of its own rather than a background process of a
  wrapper script, and a missing `virtual_ip` no longer stops the add-on: it
  logs the problem and leaves the virtual IP down, because taking the panel
  offline over a keepalived typo would remove the only place to correct it.
- **nginx's configuration and the panel's database live in `/data`**, as
  symbolic links from the paths upstream's image expects. They survive
  restarts, updates and rebuilds, and they are in Home Assistant's backups.
- **The add-on's version follows the upstream image tag one to one.** The daily
  workflow that used to bump nginx's Alpine tag and increment a patch number
  now moves both to the upstream release.
- **No wrapper entrypoint.** Upstream's image is supervised by s6-overlay; this
  add-on registers its two services (`init-addon`, `keepalived`) beside
  upstream's and lets s6 start, restart and stop everything. The shutdown
  handling the old `run.sh` needed to avoid being reported as a crash is s6's
  job now.
- **`/ssl` is mapped read-write** rather than read-only, so certificates the
  panel issues can be written where Home Assistant Core can also read them.
  `/share` is mapped as well, for static files.
- **The hourly certificate watch is gone.** It existed because the old add-on
  generated nginx's configuration itself and nothing else would reload it after
  a renewal by the Let's Encrypt add-on. Reloading is a button in the panel,
  and certificates the panel issues are reloaded by the panel.
