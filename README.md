# Home Assistant add-ons

Two add-ons for Home Assistant OS: a TLS reverse proxy, and a Fedora shell with
Podman for running your own containers alongside Home Assistant.

| Logo | Name | Description |
|---|---|---|
| <img src="tls_proxy/icon.png" width="72"> | **[TLS Proxy](tls_proxy)** | nginx terminating TLS on one port and routing to internal backends by domain, using the certificate from the official Let's Encrypt add-on. Optional failover with keepalived and a virtual IP. |
| <img src="fedora_podman/icon.png" width="72"> | **[Fedora Podman Shell](fedora_podman)** | A Fedora root shell over SSH with Podman, for running your own containers next to — but isolated from — the Supervisor's Docker. Persistent packages, the host filesystem at `/host`, background daemons without systemd. |

## Adding this repository

In Home Assistant: **Settings → Add-ons → Add-on Store**, the ⋮ menu top right,
**Repositories**, then paste:

```
https://github.com/domysh/ha-custom-addons
```

Both add-ons then appear in the store. They are built on your own machine when
you install them — there are no prebuilt images to trust, and the build is a
`Dockerfile` you can read here.

## The idea behind the two

They divide along one line: **what actually has to be an add-on.**

An add-on gets three things a plain container does not. The Supervisor starts it
in the right order at boot, Home Assistant's own paths (`/ssl`, `/share`,
`/config`) are mapped into it, and its settings get a UI. The cost is that every
upstream option has to be re-declared in an options schema, translated into
environment variables, and kept in sync with upstream by hand — and whatever is
not declared is unreachable.

**TLS Proxy** needs all three: the certificate the Let's Encrypt add-on writes
to `/ssl`, a place in the boot order before the things it fronts, and a handful
of settings that genuinely suit a form.

**Fedora Podman Shell** is the other half of the answer: a full Fedora with
Podman, reachable over SSH, with Home Assistant's shared paths mapped in and the
host's filesystem at `/host`. Anything that would otherwise be a thin wrapper
around someone else's image runs in there as a container instead, configured the
way its own documentation says — no options schema in the middle, and upstream's
own compose files work as written.

```
                    Internet
                        │
                  ┌─────▼─────┐
                  │ TLS Proxy │  certificates, boot order, routing by domain
                  └─────┬─────┘
             ┌──────────┴───────────┐
             │                      │
      Home Assistant          your containers
          Core                      │
                        Fedora Podman Shell add-on
                        (Podman, its own storage, SSH)
```

## Repository layout

```
repository.yaml              the add-on repository manifest Home Assistant reads
tls_proxy/                   add-on: nginx TLS reverse proxy
fedora_podman/               add-on: Fedora + Podman + SSH
.github/workflows/
  bump-images.yml            daily check for newer upstream base images
tools/
  make-logos.py              draws the icons and logos (Pillow), so both add-ons
                             keep one palette and geometry
LICENSE
```

Each add-on has a `README.md` for people reading the repository, a `DOCS.md`
that Home Assistant shows in its Documentation tab, and a `CHANGELOG.md`.

## Upstream versions

Base images are pinned, and a
[workflow](.github/workflows/bump-images.yml) checks daily (06:00 UTC, or on
demand) whether a newer tag exists, then commits the bump and raises the
add-on's own version so Home Assistant offers the update.

Fedora's release in `fedora_podman/build.yaml` is deliberately left manual: a
new base image invalidates that add-on's persistent system layer, which is a
decision to take deliberately.

## A word about trust

Fedora Podman Shell is as privileged as an add-on gets: full device access,
extra capabilities, no AppArmor confinement, host networking, the host's PID
namespace, the host's root filesystem at `/host`, and the Docker socket. Anyone
who can log into it owns the machine and everything Home Assistant controls with
it. That is what it is for, and it is why it authenticates by SSH key only, and
why its documentation says so more than once.

TLS Proxy is narrow by comparison: host networking, `NET_ADMIN` and `NET_RAW`
for keepalived's virtual IP, and `/ssl` mounted read-only.

## Licence

MIT. Published in case it is useful; there is no promise of support. The
defaults in each `config.yaml` are examples — review them before starting an
add-on.
