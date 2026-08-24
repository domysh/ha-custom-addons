# Fedora Podman Shell

A Fedora shell environment with Podman, reachable over SSH. It is meant to feel
close to having a root shell on the Home Assistant OS host, with the addition
of a container engine of your own that is kept separate from the Supervisor's
Docker.

Read the [Limitations](#limitations) section before you rely on this for
anything you care about. It is short and blunt on purpose.

## Requirements

**Supervisor 2026.07.1 or newer.** The manifest uses the current `app_config`
and `all_app_configs` mapped-path names, which replaced `addon_config` and
`all_addon_configs` when the Supervisor renamed add-ons to apps. Older
releases — including 2026.07.0 — do not know those names, skip the add-on as
invalid, and it simply never appears in the store. If you cannot see it at all,
check this first: *Settings → System → Repairs → ⋮ → System information*, and
look in the Supervisor log for a `Can't read .../fedora_podman/config.yaml`
line.

## Installation as a local add-on

1. Put the `fedora_podman` folder into the `addons` share on your Home
   Assistant OS machine, so that you end up with:

   ```
   /addons/fedora_podman/config.yaml
   /addons/fedora_podman/Dockerfile
   /addons/fedora_podman/build.yaml
   /addons/fedora_podman/rootfs/...
   ```

   The easiest ways to get files there are the **Samba share** add-on (the
   share is called `addons`) or the **Advanced SSH & Web Terminal** add-on
   (the folder is `/addons` from inside it). If you use this repository as a
   whole, adding its URL under *Settings → Add-ons → Add-on Store → ⋮ →
   Repositories* works too, and is easier to keep updated.

2. Make the Supervisor notice it: *Settings → Add-ons → Add-on Store → ⋮ →
   **Check for updates***, then reload the page. A **Local add-ons** section
   appears with "Fedora Podman Shell" in it.

3. Install it. The image is built on the device the first time, which on a
   Raspberry Pi 5 takes a few minutes; the build log is in the add-on's log
   tab.

4. **Turn Protection mode OFF** on the add-on's *Info* tab, then restart the
   add-on. This is not optional: the Supervisor ignores both `full_access`
   and the Docker socket mount while Protection mode is on, and Podman will
   fail to start containers.

5. Set your SSH public key in the *Configuration* tab (see below) and start
   the add-on.

## Connecting over SSH

The add-on accepts **public-key authentication only**. Password login and
empty passwords are disabled explicitly, so you must configure a key before
the first start — the add-on refuses to start without one, rather than coming
up with no way in.

On the machine you connect from:

```sh
ssh-keygen -t ed25519 -C 'home-assistant'
cat ~/.ssh/id_ed25519.pub
```

Paste that **public** line (it starts with `ssh-ed25519`) into the add-on
options:

```yaml
ssh_port: 2222
authorized_keys:
  - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... you@yourmachine
timezone: "Europe/Rome"
```

Then connect, as `root`, on the port you configured:

```sh
ssh -p 2222 root@homeassistant.local
```

Notes:

- The host keys are generated once and stored in `/config/ssh` inside the
  add-on (`/app_configs/<slug>/ssh` from the host side), so the fingerprint
  stays the same across restarts and updates. You will not be asked to accept
  a new host key every time.
- The key list is rewritten from the options on every start, so removing a key
  from the configuration actually revokes access at the next restart.
- Port `22222` is rejected: Home Assistant OS uses it for its own debug SSH.
  Port `22` is best avoided as well, since other add-ons may want it.
- Because the add-on uses host networking, the SSH port must be free on the
  **host**. If the add-on dies at start with "Address already in use", pick a
  different port.

## Using Podman

Podman is configured on every start, before SSH comes up. Check it first:

```sh
podman info
podman info --format '{{.Store.GraphDriverName}}'   # expect: overlay
```

Running something:

```sh
podman run -d --name whoami -p 8088:80 docker.io/traefik/whoami
podman ps
podman logs whoami
```

Images, containers, volumes and networks all live under `podman_storage_path`
(default `/config/podman`), which is on a mapped host path and therefore
survives add-on updates.

### Published ports, and the firewall they have to get past

```sh
podman run -d --name whoami -p 8088:80 docker.io/traefik/whoami
curl http://127.0.0.1:8088/          # from inside the add-on
curl http://<home-assistant-ip>:8088/  # from another machine
```

Two things about this are specific to running Podman inside a Home Assistant
add-on, and both look like nothing is wrong when they bite.

**There is no listening socket for a published port.** netavark forwards ports
with DNAT rules, not with a userland proxy the way Docker does, so `ss -lnt`
on the host shows nothing on 8088 even when the mapping works perfectly. Trust
a `curl`, not a socket listing.

**Something else owns the host's FORWARD chain.** The add-on runs in the
host's network namespace, so Podman's bridges and firewall rules are created
on the host — where the Supervisor's Docker has already set the iptables
FORWARD policy to `DROP` and accepts only traffic its own rules match. Since
netavark 2.x its only firewall backends are firewalld and nftables, so its
ACCEPT rules go into the `inet netavark` nftables table. That is a *different*
table from Docker's `ip filter`, and both are evaluated at the same netfilter
hook: an ACCEPT in one does not overrule a DROP in the other. The container
starts, `podman ps` shows the mapping, and the port answers nobody.

The add-on fixes this at start-up by accepting the podman bridges in Docker's
`DOCKER-USER` chain — the chain Docker jumps to first from FORWARD and never
writes to itself, which is the documented place for exactly this:

```
-I DOCKER-USER 1 -i podman+ -j ACCEPT
-I DOCKER-USER 1 -o podman+ -j ACCEPT
```

Those rules are added only when the policy really is `DROP`, only when they
are not already there, and they match nothing but `podman*` interfaces. They
are added to whichever iptables backend Docker turns out to be using: `nft`
and `legacy` keep entirely separate rule sets and cannot see each other's
chains, so the add-on looks for `DOCKER-USER` in both and uses the one that
has it. Like the bridges themselves, the rules stay on the host after the
add-on stops.

### IPv6

Published ports answer over IPv6 as well, but only because the add-on arranges
two things that are not Podman's defaults.

**Containers need an IPv6 address of their own.** netavark writes an IPv6 DNAT
rule only for a container that has one — it checks for an address in that
family before generating the rule — and Podman has no userland proxy bridging
the two families the way Docker's `docker-proxy` does. Podman's built-in
default network is IPv4-only and cannot be changed: `containers.conf` can name
the default network and give it a subnet, but that subnet must be IPv4. So the
add-on creates its own dual-stack network, `podman-dual`, and names it as the
default. `podman run -p 443:443` then answers on both families.

A container created before this existed keeps the network it was created with.
Recreate it (`podman rm` and run again, or `podman-compose down && up -d`) to
move it. Compose stacks bring their own network, so they need
`enable_ipv6: true` in their `networks:` section — both stacks in this
repository have it.

**The host has to forward IPv6**, which has a side effect worth knowing about:
the kernel stops accepting Router Advertisements on an interface once
forwarding is on, unless that interface's `accept_ra` is `2` instead of the
default `1`. On a normal LAN the host's IPv6 address and default route come
from RAs, so enabling forwarding on its own would leave Home Assistant working
until the current lease expired and then silently without IPv6. The add-on
therefore sets `accept_ra=2` on the interfaces that are relying on RAs before
it enables forwarding, and names them in the log.

`podman-diag` probes both families for every published port and says which
container has no IPv6 address.

### When a container is unreachable, or has no logs

```sh
podman-diag
```

Prints, in one go, the Podman configuration actually in effect, the containers
and their port mappings, the log driver each container was created with, both
firewall views (Docker's iptables chains and netavark's nftables table) and
the forwarding sysctls. It changes nothing.

It also probes every published TCP port along the whole path — the container's
own port over the bridge, then `127.0.0.1:<published>`, then this host's LAN
address — because those three fail differently: a service not listening, port
forwarding blocked, or something outside the host. The output says which, so
"it is not exposed" stops being one symptom with four possible causes.

A note on logs specifically: Podman picks its default log driver by reading
`/proc/1/comm`, and with the host PID namespace shared that is Home Assistant
OS's `systemd` — while the journal it would write to is in the host's mount
namespace and unreachable from here. The add-on pins `log_driver = "k8s-file"`
for that reason. The driver is fixed when a container is *created*, so a
container keeps the driver it was created with; `podman rm` and recreate one
whose logs are empty.

### Compose files

`podman-compose` is installed. It was chosen over the `docker compose` plugin
because it is a plain client that shells out to `podman`: it needs no daemon.
The Docker Compose v2 plugin talks to a Docker-compatible API socket, which
here would mean keeping a `podman system service` process running — a second
daemon to supervise in a container that deliberately has no service manager.

```sh
mkdir -p /share/compose
cat > /share/compose/stack.yml <<'EOF'
services:
  whoami:
    image: docker.io/traefik/whoami
    restart: always
    ports:
      - "8088:80"
EOF

podman-compose -f /share/compose/stack.yml up -d
```

Put compose files under a mapped path (`/share/...` or `/config/...`), not in
the container's own filesystem, or you will lose them on the next update.

`podman compose` (the subcommand) works too and is equivalent: it hands over
to an external provider, and the add-on names `podman-compose` explicitly in
`containers.conf`. Without that, Podman would pick a Docker Compose plugin if
one is installed and then fail with `failed to connect to the docker API at
unix:///run/podman/podman.sock`, because nothing here serves that socket.

If you specifically want the Docker Compose plugin instead, run
`podman system service --time=0 unix:///run/podman/podman.sock &` and point
`DOCKER_HOST` at that socket — but you are then responsible for restarting
that process yourself after every add-on restart.

### Making containers come back automatically

There is no systemd in here, so Podman's `--restart=always` policy is not
applied by anything at boot; `podman generate systemd` is likewise useless
(`podman-restart.service` is what does this job on a normal Fedora, and there
is no service manager to run it). The add-on replaces that, and the rule is the
one you would expect of an add-on rather than the one Podman's policies
describe:

1. **`autostart_containers`** (default `true`) — brings back **the containers
   that were running when the add-on last stopped**, whatever restart policy
   they carry, plus any container created with `--restart=always` or
   `--restart=unless-stopped` even if it was not running. So a plain

   ```sh
   podman run -d --name whoami -p 8088:80 docker.io/traefik/whoami
   ```

   comes back after an add-on restart or a host reboot, with nothing extra to
   remember. A container you stop yourself stays stopped, unless its restart
   policy says otherwise.

   The set of running containers is recorded while the add-on runs, in
   `autostart.list` under the Podman storage path, and refreshed whenever it
   changes. Two consequences worth knowing: the record is at most 20 seconds
   old, so a container started in the last few seconds before the add-on is
   killed may not be in it; and resetting the Podman storage resets the record
   along with everything else.

2. **`startup_compose_file`** — a path to a compose file that is brought up
   with `podman-compose ... up -d` on start, for example
   `/share/compose/stack.yml`.

3. **`startup_command`** — an arbitrary shell command, run last, for anything
   the two above do not cover.

None of the three is allowed to abort the add-on, and all three run in the
background while sshd starts. If your compose file is broken, the add-on still
comes up and SSH still works, because that is exactly when you need a shell to
fix it — and if it is merely slow (a compose project pulling several images can
take minutes), you are not locked out in the meantime. Failures are logged as
warnings in the add-on log.

Note that "automatically" here means *when the add-on starts*. If Home
Assistant restarts the add-on, or the host reboots and the add-on is set to
start on boot, your containers come back. Nothing brings them back while the
add-on is stopped.

### Storage driver, and why the add-on may refuse to start

This is a container inside a container, so the usual "overlay just works"
assumption does not hold. The add-on's own root filesystem is already an
overlay mount, and Home Assistant OS builds its kernel with
`CONFIG_OVERLAY_FS_REDIRECT_DIR` and `CONFIG_OVERLAY_FS_METACOPY` turned off,
so stacking another overlay on top of it does not work.

What makes it work anyway is that Podman's storage is **not** on the add-on's
overlay root filesystem: it is on a bind mount from the host's ext4 data
partition, where a plain overlay mount is fine. On start, the add-on performs
an actual overlay mount on your configured storage path and looks at whether
the kernel accepted it, rather than assuming:

1. native `overlay` if the probe succeeds (expected case);
2. `overlay` via `fuse-overlayfs` if it does not, but `/dev/fuse` is usable;
3. otherwise it **fails to start with an explanation**.

It never falls back to the `vfs` driver. `vfs` copies every image layer in
full instead of stacking them, which on an SD card means gigabytes wasted per
image and very slow pulls — a setup that looks like it works but quietly ruins
the disk, which is worse than not starting at all.

### Isolation from the Supervisor's Docker

Podman here has its own graph root, its own runroot, its own network
configuration directory and its own `registries.conf`. It does not read
Docker's configuration and never writes to Docker's socket, so a container you
start with Podman is invisible to Home Assistant: it will not appear as an
add-on, the Supervisor will not manage it, back it up, or restart it.

The host's Docker socket **is** mounted at `/run/docker.sock` (because
`docker_api: true`), for inspection only:

```sh
curl --silent --unix-socket /run/docker.sock http://localhost/containers/json | jq -r '.[].Names[0]'
```

Anything you write through that socket manipulates Home Assistant's own
containers directly, behind the Supervisor's back. Don't.

## Your own installations survive updates

Everything outside the mapped host paths lives in the container's writable
layer, which the Supervisor discards whenever the add-on is updated or
rebuilt — so a `dnf install` done over SSH would normally be gone at the next
update. That would make this shell disposable in a way a root shell on a real
machine is not, so the add-on does not leave it that way and there is no option
to switch: the directories a package installation touches — `/usr`, `/etc`,
`/opt`, `/root` and `/var` — are overlay-mounted with their upper layer in
`/config/system`, which is on a mapped host path. Writes go to that upper
layer; the image stays underneath as a read-only lower layer.

So you can just work normally:

```sh
dnf install -y tmux ripgrep
```

and it is still there after the add-on updates. `/var` is in the list for a
reason that is easy to miss: the RPM database lives in `/var/lib/rpm`, and
without persisting it dnf would forget everything it had installed.

**Resetting is deleting one directory.** Stop the add-on, delete
`/config/system` (it is `/app_configs/<slug>/system` from the host side), start
it again: you are back to the stock image. That is the only thing that resets
it — updating the add-on does not.

One caveat, unavoidable: **a new base image invalidates the layer.** When the
add-on is rebuilt on a newer Fedora, files kept in the upper layer would shadow
the ones the new image updated — old libraries over a new glibc, and similarly
confusing breakage. The add-on records the Fedora version the layer was created
with, and when the image no longer matches it moves the layer aside to
`/config/system.fedora-<old>.<timestamp>` and starts a fresh one, so
persistence stays active rather than quietly switching itself off. Packages you
had installed are not carried over: reinstall them, then delete the retired
directory. It is left on disk on purpose, so you can look at what was in it
first.

## Services: systemd units without systemd

Packages ship systemd unit files, and this add-on runs them:

```sh
dnf install -y netbird
systemctl enable --now netbird
systemctl status netbird
```

There is no systemd behind that, and there cannot be. systemd refuses to start
unless it is PID 1 — `src/core/main.c` checks `getpid_cached() == 1` — and this
add-on shares the host's PID namespace so that `/host` and `nsenter` work, which
makes PID 1 in here Home Assistant OS's own systemd. Nothing of ours can take
that place. The choice is between a host filesystem and a real init, and this
add-on exists for the former.

So `systemctl` is a replacement that reads the same unit files, from the same
places — `/etc/systemd/system`, `/run/systemd/system`,
`/usr/local/lib/systemd/system`, `/usr/lib/systemd/system`, drop-ins in
`<unit>.d/*.conf` included — and runs them:

```sh
systemctl start | stop | restart | try-restart UNIT
systemctl reload | reload-or-restart UNIT
systemctl kill [--signal=HUP] UNIT
systemctl enable | disable [--now] UNIT
systemctl reenable | mask | unmask UNIT
systemctl status [UNIT]              # state, main PID, drop-ins, tail of its log
systemctl is-active | is-enabled | is-failed UNIT
systemctl reset-failed [UNIT]
systemctl show [-p MainPID] UNIT     # properties, as KEY=VALUE
systemctl list-units [--all] [--type=service]
systemctl list-dependencies UNIT
systemctl cat UNIT                   # the file, its drop-ins, and where they are
```

`enable` links the unit into the `.wants` directory of every target its
`[Install]` section names — `multi-user.target` when it names none — exactly as
systemd does. Those directories are on `/etc`, which is on the add-on's
persistent layer, so what you enable once is started again every time the
add-on starts, in the order `After=` asks for.

Logs are per unit under `/var/log/addon-units/`, rotated at 5 MB, and units the
add-on started at boot also log to the Home Assistant add-on log, tagged with
the unit name (or with `SyslogIdentifier=`). There is no journal, but the
command people reach for works on those files:

```sh
journalctl -u tailscaled -f       # follow one unit
journalctl -u tailscaled -n 100   # its last hundred lines
journalctl --list-units           # everything that has logged
```

### What the add-on starts at boot

What you enabled here — not everything that is enabled.

A Fedora image arrives with units already linked into `/etc/systemd/system`:
`getty@tty1`, the `systemd-*` services and sockets, first-boot maintenance like
`selinux-autorelabel-mark` and `rpmdb-rebuild`, and — because this add-on
installs `openssh-server` — `sshd.service`. Nobody chose those here; they are
what each package's preset did while the image was being built, for a machine
that boots with a real systemd.

So the set the image came with is recorded when the image is built, and the
add-on starts what was enabled *since*: by you over SSH, or by a package you
installed at runtime. `systemctl enable` records the unit, so enabling
something the image already had works too, and means it. `systemctl list-units`
still shows everything, and the add-on log says how many it left alone.

**`sshd.service` is the exception that is always refused.** This add-on *is* an
sshd — it is how you get in — and two of them cannot hold the same port. If the
distribution's sshd starts first, the add-on's own fails to bind and the add-on
exits with `Address already in use`, which leaves no way in to undo it. Use the
`ssh_port` option to move the add-on's; a second sshd is not something to run
in here.

### What is honoured, and what is not

**`[Unit]`** — `Description`, `Documentation`, `After`, `Before`, `Requires`,
`Requisite`, `Wants`, `BindsTo`, `PartOf`, `Conflicts`, and the `Condition*` /
`Assert*` checks on paths, files, directories, users, groups, the kernel
command line, the host name and virtualisation (this is a container, so
`ConditionVirtualization=container` is true and `=no` is false).

Starting a unit pulls in what it `Requires=` and `Wants=`, ordered by `After=`;
a failed `Requires=` stops the start, a failed `Wants=` only says so. Stopping
one stops whatever declares `PartOf=` or `BindsTo=` it. `Conflicts=` is stopped
first.

**`[Service]`** — `Type=simple`, `exec`, `idle`, `notify`, `oneshot` and
`forking`; `ExecCondition`, `ExecStartPre`, `ExecStart` (several lines for
`oneshot`), `ExecStartPost`, `ExecReload`, `ExecStop`, `ExecStopPost`;
`Environment=` and `EnvironmentFile=`; `WorkingDirectory`, `RootDirectory`,
`User`, `Group`, `SupplementaryGroups`, `UMask`, `Nice`, `OOMScoreAdjust` and
`Limit*`; `PIDFile`; `Restart=` with `RestartSec`, `SuccessExitStatus`,
`RestartPreventExitStatus` and `RestartForceExitStatus`; `RemainAfterExit`;
`TimeoutStartSec` and `TimeoutStopSec`; `KillMode`, `KillSignal`,
`FinalKillSignal` and `SendSIGKILL`; `RuntimeDirectory`, `StateDirectory`,
`CacheDirectory`, `LogsDirectory`, `ConfigurationDirectory` with their
`*Mode=` and `RuntimeDirectoryPreserve=`; `StandardOutput=` and
`StandardError=` (`journal`, `null`, `file:`, `append:`, `inherit`);
`SyslogIdentifier`.

**`[Install]`** — `WantedBy`, `RequiredBy`, `Also`, `Alias`.

**Files** — drop-ins, masking (a symlink to `/dev/null`, and masking a unit
file that lives in `/etc/systemd/system` is refused rather than allowed to
delete it), line continuations, template units (`foo@bar.service`), and the
specifiers `%i %I %n %N %p %P %f %j %t %S %C %L %E %T %V %h %u %U %H %m %b %%`.

Not supported, and ignored rather than half-applied:

- **Socket, timer, path and D-Bus activation.** There is no bus and no event
  loop here, so a unit that is only ever started by one of those is never
  started. Targets are synchronisation points with nothing to execute, so they
  are inert: pulling one in starts the services *it* wants, not the target.
- **The `Type=notify` readiness protocol.** Such a unit runs as `simple`, and
  `NOTIFY_SOCKET` is deliberately left unset — which `sd_notify()` reads as
  "no manager is listening" and turns into a no-op, so the daemon runs; it just
  has nowhere to report readiness to. A unit whose `ExecStartPost` waits for
  that readiness will wait in vain.
- **The sandboxing directives** — `PrivateTmp`, `ProtectSystem`,
  `NoNewPrivileges`, `DynamicUser`, the capability sets. In here the add-on
  *is* the sandbox, and a half-applied confinement is worse than an honest
  none.
- **Resource control** — `CPUQuota`, `MemoryMax` and the other cgroup knobs.
  The add-on's own cgroup belongs to the Supervisor, and carving it up per
  service is not something to do behind your back. `Limit*` *is* applied,
  because it is per-process (`setrlimit`) and needs no cgroup.

Three differences worth knowing. `Restart=` is applied with a backoff that
grows to a minute, so a misconfigured service cannot spin; a unit that ran for
over a minute gets its short delay back. Stopping a unit signals its whole
process group — the closest thing here to systemd stopping a cgroup — so a
daemon that forked helpers does not leave them behind, and `KillMode=` chooses
between that and the main process alone. And `Exec*` lines are run through a
shell, which is more permissive than systemd, not less: the difference only
shows with shell metacharacters, and `${VAR}` expands from the unit's own
environment either way.

### VPN clients and `/dev/net/tun`

A VPN client — netbird, tailscale, wireguard-go, openvpn — needs
`/dev/net/tun`, and a container does not have it: Docker populates `/dev` with
a small fixed set of nodes and that is not among them. The add-on creates it at
start-up, which the device cgroup already permits thanks to `full_access`.

This is worth knowing because the failure is quiet: some clients do not stop
when the device is missing, they fall back to a userspace mode that proxies
only their own port, and the connection looks established while nothing on the
far side is reachable. If the node could not be created the add-on says so in
its log, which is the first place to look when a VPN client connects but
carries no traffic.

Note also that this add-on uses the host's network namespace, so a VPN
interface it brings up belongs to Home Assistant OS itself, not just to this
container: the whole machine joins that network, and it will collide with
another client of the same VPN running elsewhere on the host.

### If a unit has no unit file

Some programs install their service by writing one — `netbird service install`
is an example. That works: such installers detect systemd by looking for a
`systemctl` and at `/proc/1/comm`, ask `systemctl --version` to decide which
unit-file features they may use, then write the unit and run `enable` and
`daemon-reload`. All four are answered here, `daemon-reload` doing nothing
because nothing is cached.

Note that installing such a package often pulls the systemd package itself in,
for its scriptlets. That is harmless: `systemctl` still resolves to the
replacement, because `/usr/local/bin` comes first in `PATH` and the replacement
does not hand over to the real binary — which could only refuse, having no
systemd to talk to.

For a program that ships no unit at all, writing one is the same work as
writing any other service file, and it belongs in `/etc/systemd/system`:

```ini
[Unit]
Description=My daemon

[Service]
ExecStart=/usr/local/bin/mydaemon --foreground
Restart=always

[Install]
WantedBy=multi-user.target
```

The one rule that matters: **either the command stays in the foreground, or it
says where it went.** A unit whose `ExecStart` daemonises needs
`Type=forking` *and* a `PIDFile=`; that PID is then the unit's, and it is
watched and stopped like any other. `Type=forking` without a `PIDFile=` leaves
nothing to supervise and nothing to stop — the add-on says so in the log and
leaves it alone rather than restarting a program that is already running.

## Resetting the add-on

Uninstalling the add-on does **not** clear its state: `/config` is a mapped
host path (`/app_configs/fedora_podman` from the host side), so the Podman
storage, the persistent system layer and the SSH host keys all outlive it, and
reinstalling picks them straight back up. That is usually what you want, and
occasionally exactly what you do not — hence:

```sh
addon-reset --help          # what can be reset
addon-reset --podman        # images, containers, volumes, networks
addon-reset --system        # everything installed with dnf, edits to /etc
addon-reset --autostart     # only the record of which containers were running
addon-reset --ssh           # host keys, so new ones are generated
addon-reset --all
addon-reset --status        # is anything queued?
addon-reset --cancel        # drop it
```

It prints exactly what will be deleted and asks you to type `reset` to
confirm — `--yes` skips that for scripts.

**It queues the reset; the next add-on start performs it.**

```sh
ha addons restart fedora_podman
```

That indirection is not caution for its own sake: most of what there is to
reset is in use by the shell you are typing in. `/usr`, `/etc`, `/opt`, `/root`
and `/var` are overlay mounts whose upper layer is the thing to delete, and
that cannot be pulled out from under running processes — the shell itself lives
there. Podman's storage has containers running out of it. At start-up neither
is true yet, so the entrypoint does the deleting before it mounts the system
layer and before it configures Podman.

The request is a file in `/data`, the add-on's Supervisor-managed directory,
which is not one of the things being reset. It is deleted *before* the deleting
starts, so a reset that fails halfway — or that is itself what stops the add-on
from starting — cannot repeat on the next start and leave the add-on wiping its
own state for ever. It is one-shot by construction, so there is no switch left
on that quietly resets you again next month.

Two things `addon-reset` deliberately does not cover, because they already have
their own reset: the container filesystem outside the persistent layer, which
is rebuilt on every add-on update anyway, and the add-on options, which are
edited in the *Configuration* tab.

## The `ha` command

The Home Assistant CLI is installed, the same `ha` you get in the official SSH
add-on:

```sh
ha core restart
ha addons list
ha supervisor logs
ha backups new --name "before I break something"
ha network info
```

It authenticates with the `SUPERVISOR_TOKEN` the Supervisor gives the add-on
(`hassio_api: true`), and the add-on asks for the `admin` role so that the
add-on, supervisor, host and backup subcommands work rather than returning
403. If you would rather not grant that, lower `hassio_role` in `config.yaml`
to `manager` or `default`; `ha` stays installed, it just refuses more.

## Reaching the host filesystem

The add-on manifest cannot bind-mount an arbitrary host path: the Supervisor
builds the mount list itself from a fixed set of map types, and there is no
escape hatch for `/`. What it can do is share the host's PID namespace, which
this add-on does (`host_pid: true`), and that is enough:

```sh
ls /host            # the host's real root filesystem
cat /host/etc/os-release
```

### Why `/host` is a symlink and not a bind mount

`/host` is a symlink to `/proc/1/root`. That is not a fallback for a bind
mount, it is the only form that works, and the reason is worth stating because
the obvious-looking alternative fails quietly.

`/proc/<pid>/root` is a magic link, not an ordinary symlink: the kernel
resolves paths under it *inside that process's mount namespace*. Reading
`/host/mnt/data` therefore walks the host's own mount table and crosses into
whatever the host has mounted there, even though none of those mounts exist in
the add-on's namespace.

`mount --bind /proc/1/root /host` does not do that. `mount(8)` canonicalises
its source in userspace first — it reads the link, gets `/`, and binds the
add-on's *own* root onto `/host`. The result looks plausible and is completely
wrong: `/host/etc/os-release` says `Fedora Linux 44 (Container Image)` and
`/host/mnt` is empty. `--no-canonicalize` does not rescue it either; the kernel
rejects a `/proc/<pid>/root` source for a bind. And even a bind that did take
would only copy the one mount, never the submounts underneath it — those live
in the host's namespace and cannot be moved into ours.

So the symlink is what gives the full picture:

```
Host filesystem available at /host (Home Assistant OS 18.2), submounts included
```

Re-mounting the host's block devices under `/host` is the other approach, and
it is worse: it needs `/proc/1/mountinfo` parsed, it gets the paths wrong for
the directories Home Assistant OS bind-mounts out of its partitions, and it
cannot reach a `tmpfs` at all. The symlink needs none of it.

One consequence to be aware of: because path resolution happens in the host's
namespace, `/host` shows the host's view and only that. It does not show the
add-on's mapped paths — `/config`, `/share` and friends exist in this
container's namespace, not the host's, so look for them under
`/host/mnt/data/supervisor/...` where the host actually keeps them.

For a genuine host shell — the host's mount, network and PID namespaces, the
same thing the "Advanced SSH & Web Terminal" add-on gives you — use `nsenter`:

```sh
nsenter -t 1 -m -u -i -n -p -- /bin/sh
```

**Both need Protection mode to be off**, and this is the failure worth knowing
about: the Supervisor applies `host_pid` only when Protection mode is off, and
ignores it silently otherwise. With it on, PID 1 inside the container is the
add-on's own init, so `/proc/1/root` is the *container's* root — and `/host`
would give you a perfectly browsable, completely useless view of the add-on's
own filesystem, with nothing to signal that it is not the host.

The add-on therefore checks before trusting it: it compares the device and
inode of `/` and `/proc/1/root`, and — since two containers from this same
image would differ there while still both being containers — compares the two
`/etc/os-release` files as well. When they match it says so in the log instead
of pretending `/host` is the host.

It also asks the host's Docker how this container was actually started, and
prints the answer at every boot:

```
Runtime state as reported by the host Docker:
  PidMode      : host
  Privileged   : false
  Added caps   : SYS_ADMIN NET_ADMIN SYS_RESOURCE SYS_PTRACE DAC_READ_SEARCH
```

`PidMode: host` means the host PID namespace really is shared and `/host` will
work. Anything else means the Supervisor dropped `host_pid`, which it only does
with Protection mode on. This is read-only use of the Docker API (`GET`), and
starts nothing.

Note that the Docker API is no way around this: there is no call that adds a
bind mount to a container that is already running. Mounts are fixed when a
container is created, so short of starting a second container the host's PID
namespace is the only route to the host filesystem.

**Writes through `/host` are writes to the real host filesystem.** There is no
undo, no layer, and nothing sandboxing it. Note also that most of the Home
Assistant OS root filesystem is mounted read-only by design, and that the parts
that are writable (`/mnt/data`) are what Home Assistant itself is running out
of.

## Options

| Option | Type | Default | Meaning |
|---|---|---|---|
| `ssh_port` | port | `2222` | Port sshd listens on, on the host's network stack. `22222` is rejected. |
| `authorized_keys` | list of str | *(empty)* | SSH public keys allowed to log in as root. At least one is required. |
| `timezone` | str | `Europe/Rome` | IANA timezone name, used for the container and for shell sessions. |
| `podman_storage_path` | str | `/config/podman` | Where Podman keeps images, containers, volumes and networks. Must be on a mapped path. |
| `autostart_containers` | bool | `true` | Bring back the containers that were running when the add-on last stopped, plus any created with `--restart=always`. |
| `startup_compose_file` | str | *(empty)* | Compose file brought up with `podman-compose up -d` at start. |
| `startup_command` | str | *(empty)* | Shell command run at the end of startup. |

There is no option for installing extra packages and none for turning
persistence on: `dnf install` over SSH is persistent by itself (see above),
which is what such an option would have been for.

## What the add-on is granted, and why

| Setting | Reason |
|---|---|
| `full_access: true` | Device cgroup rule `a *:* rwm`, so USB and other hardware can be passed into Podman containers. **Ignored unless Protection mode is off.** |
| `privileged: [SYS_ADMIN, NET_ADMIN, SYS_RESOURCE, SYS_PTRACE, DAC_READ_SEARCH]` | `full_access` grants devices, not capabilities. `SYS_ADMIN` for the mounts every container start performs, `NET_ADMIN` for netavark's bridges and firewall rules, `SYS_RESOURCE` for `--ulimit`, `SYS_PTRACE` for `podman exec`/`top`, `DAC_READ_SEARCH` for reading image layers owned by other UIDs. |
| `apparmor: false` | The default profile denies `mount(2)` and `pivot_root(2)`, which the container runtime needs for every container. Nested containers cannot work with it on. If something is still denied, check `dmesg` on the host for `apparmor="DENIED"`. |
| `host_network: true` | sshd and published container ports land directly on the host's network stack, no port mapping. The cost is that ports must be free on the host. |
| `host_pid: true` | Shares the host's PID namespace. Podman does not need it, but it is the only way to reach the host filesystem (`/host` -> `/proc/1/root`) and to `nsenter` into a host shell, since a manifest cannot declare an arbitrary bind mount. It also makes host processes visible to `htop` and friends. |
| `docker_api: true` | Mounts the host Docker socket for inspection. Also ignored while Protection mode is on. |
| `hassio_api: true` + `hassio_role: admin` | Provides the `SUPERVISOR_TOKEN` the `ha` CLI authenticates with, at a role that lets it manage add-ons, the supervisor, the host and backups. |
| `kernel_modules: true` | Bind-mounts `/lib/modules` read-only and adds `SYS_MODULE`, so `modprobe overlay` / `modprobe fuse` work where those are modules. |
| `udev: true` | Provides the host udev database, so devices passed into containers can be identified by udev properties. |
| `init: true` | Docker's tini runs as PID 1 and reaps orphans. When podman exits, the conmon processes supervising your containers reparent to PID 1, and sshd only reaps its own children. |

## Limitations

Read this part.

- **This add-on is a Supervisor-managed container.** Stopping it, updating it,
  rebuilding it or uninstalling it kills every container running inside it,
  immediately and without warning. Your containers are not add-ons; the
  Supervisor does not know they exist.
- **Anything not on a mapped path and not on the persistent system layer is
  lost on every update.** `/usr`, `/etc`, `/opt`, `/root` and `/var` are
  covered (see above), so packages, shell history and configuration survive;
  anything else — `/srv`, `/mnt`, a file left in `/tmp` — does not. Persistent
  paths are `/config`, `/share`, `/media`, `/backup`, `/homeassistant` and
  `/app_configs`. Everything else is the container's writable layer, which
  is thrown away.
- **Uninstalling does not clean up.** Everything on the mapped paths — the
  Podman storage, the persistent system layer, the SSH host keys — survives
  uninstalling the add-on and is picked back up if you reinstall it. Use
  `addon-reset` (see above) to get a clean slate deliberately.
- **Home Assistant backups do not cover your containers usefully.** The add-on
  backup captures `/config` (which by default includes Podman's storage, and
  can therefore be very large), but nothing coordinates a consistent snapshot:
  databases inside your containers are backed up mid-write.
- **No resource isolation.** CPU, RAM, disk I/O and disk space are shared with
  Home Assistant itself, with no limits and no guarantees. A container that
  eats the SD card or the RAM will take Home Assistant down with it. On a
  Raspberry Pi this is easy to do by accident.
- **Wide-open security boundary.** This add-on runs with full device access,
  extra capabilities, no AppArmor confinement, host networking, the host PID
  namespace, the host's root filesystem at `/host` and the Docker socket.
  Anyone who can log in over SSH effectively owns the machine and everything
  Home Assistant controls, and can modify the host OS itself. Guard the private
  key accordingly.
- **`/host` writes are permanent and unprotected.** There is no layering and no
  undo: a mistaken `rm` under `/host` damages the actual Home Assistant OS
  installation, not a container copy.
- **Host networking means port collisions are real.** Anything you publish
  from a Podman container binds on the host, competing with Home Assistant,
  other add-ons and the host's own services.
- **Podman networks touch the host's network stack, and outlive the add-on.**
  Because the add-on shares the host network namespace, bridges and firewall
  rules created by netavark are created there, alongside Docker's, and stopping
  the add-on does not remove them. The add-on cleans up leftover `podmanN`
  bridges when it starts. The add-on also remounts
  `/proc/sys` read-write so netavark can set the sysctls it needs, which means
  the host's network sysctls are writable from inside — by netavark, and by
  anything else with a shell here. They do not conflict in normal use, but
  they are not invisible either.
- **Updating the add-on rebuilds the image from Fedora.** The base Fedora
  release is pinned in `build.yaml`, but the packages on top are whatever
  Fedora ships that day. A rebuild can therefore pick up a new Podman version
  with different behaviour.

## Troubleshooting

**The add-on refuses to start with "No usable Podman storage driver".**
Protection mode is almost certainly still on; turn it off in the *Info* tab
and restart. Otherwise check that `podman_storage_path` is on a mapped path.

**`podman info` fails, or containers fail to start with cgroup errors.**
Protection mode again, or the kernel refusing the cgroup setup. Run
`podman info` over SSH and read the actual error; the add-on deliberately
starts anyway so that you have a shell to debug from.

**SSH refuses my key.** Check the add-on log: invalid entries in
`authorized_keys` are rejected at start with an explicit message. Make sure
you pasted the `.pub` file's contents, not a path and not the private key.

**"Address already in use" at start.** With host networking the SSH port must
be free on the host. Something else — possibly another add-on — already has
it. Change `ssh_port`.

**`/host` does not exist, or shows the add-on's own filesystem.** Protection
mode is on, so the host PID namespace is not shared and there is no way to
reach the host's root. Turn it off in the *Info* tab and restart. Newer
versions of the add-on refuse to create `/host` in that situation rather than
exposing a misleading copy.

**A container fails to start with `aardvark-dns failed to start ... Cannot
assign requested address`.** Podman's bridges are created in the *host* network
namespace, because the add-on runs with host networking, so they outlive the
add-on: stopping it kills the containers but leaves the bridges on the host. A
run that failed halfway can leave one without its gateway address, netavark
then reuses that half-configured bridge, and aardvark-dns cannot bind the
gateway it expects — which restarting the add-on does not fix, making it look
permanent. The add-on deletes leftover `podmanN` bridges at start-up (safe:
none of its containers can be running at that point) and lets netavark rebuild
them. If you hit it on a running add-on, `podman-compose down`, then
`ip link delete podmanN`, then bring it back up.

**A container fails to start with `netavark: set sysctl ...: Read-only file
system`.** Same root cause as the cgroup one below: Docker mounts `/proc/sys`
read-only in containers that are not truly privileged, and netavark configures
each bridge it creates through sysctls. The add-on remounts `/proc/sys`
read-write at start-up; if you still see it, the remount was refused and the
log says so — check Protection mode. As a stop-gap, `podman run --network=host`
does not use netavark at all.

**`podman run` fails with `mkdir /sys/fs/cgroup/...: read-only file system`.**
Docker mounts `/sys/fs/cgroup` read-only in every container that is not truly
privileged, and the Supervisor never passes `--privileged` — `full_access` only
adds device rules. The add-on remounts it read-write at start-up; if you still
see this, the remount was refused, which the log will say. Check that
Protection mode is off and restart. As a stop-gap, `podman run --cgroups=disabled ...`
runs containers without their own cgroup (and therefore without resource limits).

**Containers run but `--memory` / `--cpus` have no effect.** The cgroup
controllers could not be delegated, which the start-up log reports. Containers
still work; only limits are unavailable.

**Podman pulls are extremely slow and the disk fills up.** Check
`podman info --format '{{.Store.GraphDriverName}}'`. If it says `vfs`, the
configuration was overridden somewhere; the add-on itself never configures it.
