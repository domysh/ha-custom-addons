# Changelog

## 1.2.1

- **Only start units that were enabled here.** 1.2.0 widened the boot scan from
  `multi-user.target.wants` to every `.wants`/`.requires` directory, which is
  what systemd does — and swept up everything a Fedora image arrives with
  enabled: `getty@tty1`, the `systemd-*` services and sockets, first-boot
  maintenance like `selinux-autorelabel-mark` and `rpmdb-rebuild`, and
  `sshd.service`, which this add-on installs `openssh-server` for.

  The last one is fatal rather than noisy: the distribution's sshd binds port
  22 before the add-on's own gets there, so the add-on exits with `Address
  already in use` on every start — and since its sshd is how you get in, there
  is no way left to turn the offending unit off.

  The set the image came with enabled is now recorded when the image is built,
  and the boot starts what was enabled *since* — by you, or by a package
  installed at runtime. `systemctl enable` records the unit, so enabling
  something the image already had works too. `sshd.service` is refused either
  way, with a line in the log saying so and pointing at the `ssh_port` option.

## 1.2.0

The unit runner grew up. It started as enough of systemd to run a unit file,
and unit files in the wild turned out to use a great deal more of systemd than
that — so this reads most of what a service unit actually contains.

Found by a real failure: `tailscaled` refusing to start with `invalid value ""
for flag -port: can't be the empty string`. Its unit has `Environment="PORT=41641"`
and `ExecStart=... --port=${PORT}`. systemd strips those quotes; this did not,
so the assignment was to a variable named `"PORT`, which is not a valid name,
so it silently did not happen, so `${PORT}` expanded to nothing. Values are now
split the way systemd splits them — quotes removed, several assignments per
line, `\` escapes inside double quotes — and the same parser reads
`EnvironmentFile=`, which used to be *sourced* as a shell script (it is not
one: a value with spaces was mangled and anything executable in it ran).

That unit needed three more things this did not do, and now does:

- **`RuntimeDirectory=`, `StateDirectory=`, `CacheDirectory=`,
  `LogsDirectory=`, `ConfigurationDirectory=`** with their `*Mode=`, created
  before the service starts and owned by its `User=`. Without them a daemon
  that expects `/run/<name>` to be there fails in a way that reads as its own
  fault — `tailscaled` cannot create its socket and exits.
  `RuntimeDirectory=` is removed again when the unit stops, unless
  `RuntimeDirectoryPreserve=` says otherwise.
- **`ExecStopPost=`**, and `ExecStop=`/`ExecReload=`/`ExecStartPre=`/
  `ExecStartPost=` as repeatable lists rather than one line each. `ExecStop`
  now runs on `systemctl stop`, `ExecStopPost` whenever the service stops,
  however it stopped — which is what runs `tailscaled --cleanup`.
- **`Type=notify`** is still run as `simple`, but `NOTIFY_SOCKET` is now
  deliberately left unset, which `sd_notify()` treats as "no manager
  listening". It was never set before either; the difference is that this is
  now written down as a decision rather than an omission.

Two bugs that predate all of this, both found by testing rather than by use:

- **A service's exit status was always read as 0.** The status was taken from
  `PIPESTATUS` *after* a `set +m` — and `set` is itself a pipeline, so it
  overwrote the value being read. `Restart=on-failure` could therefore never
  see a failure, and a crashed service was logged as "exited with status 0".
- **`Type=forking` never worked**, despite being listed as supported. The
  start command's output went through the same pipeline as everything else,
  and a pipeline does not end until every process holding it has exited — the
  forked daemon inherits it, so the supervisor waited for the daemon it was
  supposed to be *starting*. Forking units now have their own path: the
  initial process's output goes straight to the unit's log, the `PIDFile=` is
  removed first so a stale one cannot be read as the new PID, and the daemon
  named in it is what gets watched and stopped.

The rest, in one list:

- `[Unit]` dependencies are acted on: `Requires=`, `Requisite=`, `Wants=` and
  `BindsTo=` are pulled in when a unit is started, ordered by `After=`/
  `Before=`; a failed `Requires=` stops the start where a failed `Wants=` only
  reports; `Conflicts=` is stopped first; and stopping a unit stops whatever
  declares `PartOf=` or `BindsTo=` it. The boot sequence is ordered the same
  way instead of starting everything at once.
- `Condition*=` and `Assert*=` on paths, files, directories, users, groups,
  the kernel command line, the host name and virtualisation, with `!`
  negation. An unmet condition is a skip, not a failure — as in systemd — and
  `ConditionVirtualization=no` is honestly false in here.
- **Drop-ins**: `<unit>.d/*.conf` in every unit directory, template drop-ins
  included, applied in file-name order. Which needed the other half of the
  rule to be useful: an empty assignment (`ExecStart=`) clears the list before
  the new value is added, which is how a drop-in replaces a command instead of
  adding a second one.
- **Masking**: `systemctl mask`/`unmask`, and a masked unit is refused
  everywhere, including at boot. Masking a unit file that lives in
  `/etc/systemd/system` is refused rather than allowed to overwrite it — the
  unmask would have deleted it.
- `enable` honours the unit's own `[Install]` section — `WantedBy=`,
  `RequiredBy=`, `Also=`, `Alias=` — instead of always linking into
  `multi-user.target.wants`.
- A **failed** state that survives the process: `systemctl is-failed`,
  `reset-failed`, and `status` showing the exit status that caused it.
  `RemainAfterExit=yes` reports `active (exited)`, so a `oneshot` that set
  something up still counts as in effect.
- `Restart=` understands `on-success`, `on-abnormal` and `on-abort` alongside
  `always`/`on-failure`, plus `SuccessExitStatus=`,
  `RestartPreventExitStatus=` and `RestartForceExitStatus=`. Time values are
  parsed as systemd writes them (`100ms`, `5s`, `1min 30s`, `infinity`).
- Stopping honours `KillMode=`, `KillSignal=`, `FinalKillSignal=` and
  `SendSIGKILL=`; `TimeoutStopSec=infinity` is capped, because the Supervisor
  gives the container ten seconds and a promise nothing can keep is worse than
  a number.
- Per-process limits are applied: `Limit*` (as `ulimit`), `Nice=`, `UMask=`,
  `OOMScoreAdjust=`, `Group=` and `SupplementaryGroups=` (`User=` alone used
  to pass the user name as the group). Cgroup resource control stays ignored,
  and DOCS.md says why.
- `StandardOutput=`/`StandardError=`: `null`, `file:`, `append:`, `inherit`,
  with an unwritable target falling back to the unit log instead of killing
  the service. `SyslogIdentifier=` sets the tag its lines carry.
- New commands: `show` (KEY=VALUE properties, which is what installers parse),
  `list-dependencies`, `kill --signal=`, `reenable`, `try-restart`,
  `reload-or-restart`, `is-failed`, `reset-failed`, `mask`, `unmask`, and
  `list-units --all --type=`. `status` lists drop-ins and exits 3 for an
  inactive unit, as systemd's does.
- The full specifier set (`%t %S %C %L %E %h %u %U %H %m %b %p %P %f %j` and
  the ones that were already there), so `RuntimeDirectory=%p` and friends
  resolve to the same paths this creates.
- **`journalctl`**: `-u`, `-f`, `-n`, `-r`, `--list-units`. There is no
  journal, but every unit's output is captured to a file, and the command
  people reach for while a service misbehaves now works on those files. The
  options that need a real journal (`-b`, `--since`) say so rather than
  quietly returning something else.

## 1.1.1

- Stop handing over to a real `systemctl` when one is on disk. Packages that
  ship a unit file commonly pull the systemd package in for their scriptlets,
  so a real binary is easy to end up with — and it cannot work here, since
  nothing in this add-on can be PID 1. Deferring to it replaced a working
  service manager with one that only ever prints "System has not been booted
  with systemd". The replacement now answers regardless; the real binary is
  still reachable by its own path.
- Answer `systemctl --version`. Installers parse it: `kardianos/service`, which
  netbird and others use to install themselves, matches `systemd ([0-9]+)` to
  decide which unit-file features it may use, and assumes the worst without a
  parseable answer. The number is a compatibility claim and the line says so.
- Say once at start-up, when the systemd package is present, that `systemctl`
  resolves to the replacement — otherwise it is a confusing thing to run into.

## 1.1.0

- **Services now come from their own systemd unit files.** `dnf install` a
  package, `systemctl enable --now` it, and it runs — and starts again when the
  add-on does. The previous mechanism asked for an executable file per service
  in `/config/services`, which meant translating by hand what the package had
  already shipped, and it is removed together with `addon-service` and its
  example services.
  There is still no systemd, and there cannot be: it refuses to start unless it
  is PID 1, and this add-on shares the host's PID namespace so that `/host` and
  `nsenter` work, which makes PID 1 the host's own systemd. `systemctl` is
  therefore a replacement that reads the same unit files from the same
  directories and runs them.
  Honoured: `Type=simple`/`exec`/`notify`/`idle`/`oneshot`/`forking`, the
  `Exec*` lines, `Environment=`, `EnvironmentFile=`, `WorkingDirectory=`,
  `User=`, `Restart=` with `RestartSec=`, `TimeoutStopSec=`, `WantedBy=`, line
  continuations and template units. Ignored rather than half-applied: socket
  and timer activation, the notify protocol, dependency ordering, and the
  sandboxing directives — in here the add-on is the sandbox.
  `enable` links into `multi-user.target.wants` as systemd does, which is on
  the persistent layer, so it survives updates. `daemon-reload` is accepted and
  does nothing, so installers that write a unit and call it — `netbird service
  install` among them — complete.
- Each service runs in a process group of its own and is stopped as a group,
  which is the closest thing here to systemd stopping a cgroup: a daemon that
  forked helpers does not leave them running.
- Logs are per unit in `/var/log/addon-units/`, rotated at 5 MB, and units
  started at boot also reach the Home Assistant add-on log.

## 1.0.3

- Drop netavark's leftover firewall rules at start-up. netavark removes a
  container's rules when it stops, but nothing stops the containers when the
  add-on is killed or the machine loses power — and since the add-on shares the
  host's network namespace, those rules stay in the host's nftables ruleset and
  accumulate. This is not merely untidy: `NETAVARK-HOSTPORT-DNAT` is evaluated
  in order, so rules belonging to a destroyed network are matched *before* the
  live ones and translate a published port to a container address that no
  longer exists. The port then times out instead of being refused, or answers
  on one address family while black-holing the other. At start-up no container
  of ours can be running, so the table is dropped and netavark rebuilds it.
- `podman-diag` names netavark chains whose network no longer exists, rather
  than leaving them to be spotted in the full ruleset dump.
- `podman-diag` shows the host address each port is published on, and explains
  the IPv6 result in terms of it. netavark writes rules for an address family
  only when the port is bound to an address of that family, so a port published
  on `127.0.0.1` or `0.0.0.0` has no IPv6 rules by design — the previous text
  blamed the container's own address, which sent the reader looking in the
  wrong place.

## 1.0.2

- Fix containers failing to start with `enabling controller cpuset: ...
  cgroup.subtree_control: no such file or directory`. Podman reads
  `/sys/fs/cgroup/cgroup.controllers` and writes that whole list into every
  container's cgroup without checking which controllers are actually
  delegated, so one controller missing from the add-on's own
  `cgroup.subtree_control` fails the container outright — naming the first
  controller in the list, `cpuset`, whatever the real cause. The delegation
  that has to happen first was too fragile: cgroup.procs is generated on read
  and shifts as processes are moved out of it, so a single sweep left
  stragglers behind, and the kernel refuses to delegate while any process
  remains in the cgroup root. The processes are now moved out in repeated
  sweeps until none is left, and a transient `EBUSY` is retried.
- Report what actually happened. Delegation failures were discarded, leaving
  the add-on log claiming success while every container start failed with an
  error that names the container's cgroup rather than the add-on's. Each
  controller that could not be delegated is now listed with the kernel's own
  reason, and what it means for containers.
- `podman-diag` shows `cgroup.controllers` against `cgroup.subtree_control` and
  names the difference, along with any process left in the cgroup root.

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
