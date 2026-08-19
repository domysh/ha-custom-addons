# Changelog

## 1.0.1

- Fix an empty `/etc/resolv.conf`, which left the shell with no name resolution
  on every start. Docker provides `/etc/resolv.conf`, `/etc/hosts` and
  `/etc/hostname` as individually bind-mounted files, and the persistent
  system layer covers `/etc` with an overlay: overlayfs builds its view from
  the lower filesystem's directory entries rather than from what is mounted on
  top of them, so the base image's empty copy resurfaced. The three files are
  now copied out before `/etc` is covered and bind-mounted back over the
  overlay, from a tmpfs, so per-boot facts never end up in the persistent
  layer.
- Explain a storage directory that suddenly looks empty. An add-on's `/config`
  is `app_configs/<slug>`, and the slug depends on the install source — a local
  folder and a repository produce different ones — so reinstalling from the
  other source yields an empty `/config` while the previous one sits intact
  under its old name, with every image, container and installed package in it.
  When the Podman storage is empty and a neighbouring directory holds what
  looks like a previous installation, start-up now names it, with its size and
  the commands to take it back.

## 1.0.0

First public release.

### Shell and access

- Fedora 44 base image, `aarch64` and `amd64`, built on the target machine.
- SSH on a configurable port (2222 by default), public-key authentication only;
  password and empty-password authentication are disabled explicitly. Host keys
  are generated once and kept on a mapped path, so the fingerprint survives
  restarts and updates.
- The `ha` CLI, with `hassio_api` and the `admin` role, so its add-on,
  supervisor, host and backup subcommands work rather than returning 403.
- Options are validated at start-up with actionable errors instead of a broken
  runtime state: missing or malformed SSH keys, a private key pasted by
  mistake, an unknown timezone, the reserved port 22222, and a Podman storage
  path that would not survive an update.

### Podman

- Podman with `podman-compose`, `crun`, `netavark` and `aardvark-dns`, kept
  separate from the Supervisor's Docker: its own graph root, runroot, network
  configuration and registries. The Docker socket is mounted for inspection
  only and is never written to.
- Storage on a configurable mapped path (`/config/podman` by default) covering
  images, containers, volumes and networks, so all of it survives an add-on
  update. The path is verified to be a real mapped mount, by comparing its
  backing device with the one behind `/`, rather than trusted for looking like
  one.
- The storage driver is chosen by performing an actual overlay mount on the
  configured path at start-up: native `overlay`, otherwise `overlay` through
  `fuse-overlayfs`, otherwise the add-on refuses to start. It never falls back
  to `vfs`, which would silently waste tens of gigabytes on SD-card storage.
- `/sys/fs/cgroup` and `/proc/sys` are remounted read-write at start-up, and
  cgroup v2 controllers are delegated to a child cgroup. Docker mounts both
  read-only in any container that is not truly privileged, which otherwise
  makes every `podman run` fail — on cgroup creation, and again on the sysctls
  netavark sets for each bridge.
- Leftover `podmanN` bridges are removed at start-up. They are created in the
  host's network namespace and outlive the add-on, and a half-configured one
  makes aardvark-dns fail to bind its gateway in a way that restarting does not
  clear.
- Published ports are reachable on IPv4 and IPv6. Containers run on a
  dual-stack network created by the add-on, because Podman's built-in default
  network is IPv4-only and cannot be changed, and netavark writes IPv6 DNAT
  rules only for containers that have an IPv6 address.
- Port forwarding is allowed through the host firewall: the Supervisor's Docker
  sets the iptables FORWARD policy to `DROP`, and netavark's ACCEPT rules live
  in a separate nftables table that cannot override it, so the add-on adds the
  Podman bridges to Docker's `DOCKER-USER` chain. IPv6 forwarding is enabled
  with `accept_ra=2` set first, so the host does not lose its own IPv6
  address.
- Container logging uses the `k8s-file` driver explicitly. Podman would
  otherwise pick journald, having found the host's systemd as PID 1, and write
  to a journal socket that does not exist in this container.

### Persistence

- Packages installed with `dnf` over SSH survive add-on updates: `/usr`,
  `/etc`, `/opt`, `/root` and `/var` are overlay-mounted with their upper layer
  on a mapped path. `/var` is included because the RPM database lives there.
- Rebuilding on a newer Fedora retires the old layer to a timestamped directory
  and starts a fresh one, rather than letting stale files shadow the ones the
  new image updated.
- Containers that were running when the add-on stopped are started again when
  it starts, whatever restart policy they carry, along with anything created
  with `--restart=always`. An optional compose file and startup command are
  applied too.
- `addon-reset` resets the Podman storage, the persistent system layer, the
  autostart record or the SSH host keys. It queues the work for the next start,
  because those are in use by the shell that asks for it.

### Host access

- The host's root filesystem at `/host`, through the host PID namespace. It is
  a symlink to `/proc/1/root`, which the kernel resolves inside the host's
  mount namespace, so the host's own submounts are reachable through it.
- `nsenter` for a genuine host shell, and host processes visible to tools like
  `htop`.
- The add-on reports at every start how the Supervisor actually created it —
  PidMode, Privileged, added capabilities — since several of its abilities are
  granted by the manifest but applied only when Protection mode is off.

### Services and diagnostics

- Background daemons without systemd: an executable file in `/config/services`
  is started when the add-on starts and restarted when it exits, with a backoff.
  `addon-service` manages them, `systemctl` explains why it cannot work.
- `/dev/net/tun` is created at start-up, since Docker does not provide it and
  VPN daemons silently degrade without it.
- `podman-diag` prints the Podman configuration in effect, the containers and
  their mappings, both host firewall views, and probes every published port
  from the container, the host and over IPv6, to show where the path breaks.
