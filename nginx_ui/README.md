# Nginx UI add-on

nginx with [Nginx UI](https://github.com/0xJacky/nginx-ui) as its control
panel: sites, streams, TLS certificates, log search and a config editor, all
from the browser instead of from an add-on options schema.

- Upstream's official image, pinned to an exact tag and updated by a workflow
  in this repository, so the add-on's version *is* the upstream version.
- Six options: five say how to reach the panel, one turns on keepalived.
  Everything nginx does is configured in the panel.
- `/data` holds nginx's configuration and the panel's database, so both survive
  updates and are included in Home Assistant backups.
- Optional failover with keepalived and a virtual IP, carried over unchanged
  from the TLS Proxy add-on this replaces.

**[Full documentation: DOCS.md](DOCS.md)** — that is also what the add-on's
Documentation tab shows.

```
config.yaml                 add-on manifest: options schema, permissions
Dockerfile                  upstream's image + keepalived + the files below
DOCS.md                     user-facing documentation
rootfs/
  etc/s6-overlay/s6-rc.d/
    init-addon/             oneshot: /data symlinks, options -> environment,
                            keepalived.conf; everything else depends on it
    keepalived/             longrun: the virtual IP, idle unless ha.enabled
    init-config/            \ dependency files only, so upstream's own
    nginx-ui/               / services start after init-addon
    user/contents.d/        registers the two new services
  usr/local/bin/
    generate-keepalived-conf.sh   options -> keepalived configuration
```

The image's entrypoint is s6-overlay's, and the two services added here are
registered the same way upstream registers nginx and nginx-ui: there is no
wrapper script in front of them.
