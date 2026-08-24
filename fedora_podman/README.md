# Fedora Podman Shell add-on

A Fedora shell environment with [Podman](https://podman.io/), reachable over
SSH, for running your own containers on a Home Assistant OS machine without
going through the Supervisor's Docker.

Built for **aarch64** (Raspberry Pi 5) with **amd64** support kept alongside it.
Requires **Supervisor 2026.07.1 or newer** (it uses the current `app_config` /
`all_app_configs` mapped-path names; on older releases the add-on does not
appear in the store at all).

## What it gives you

- A root shell over SSH on a current Fedora userland, with public-key
  authentication only and a persistent host key.
- Podman and `podman-compose`, with storage on a mapped host path so images
  and containers survive add-on updates.
- Deliberate isolation from the Supervisor's Docker: separate graph root,
  network configuration and registry configuration. The host Docker socket is
  mounted for inspection only.
- Full device access and host networking, so USB hardware and published ports
  behave the way they would on the host.
- The host's real root filesystem at `/host`, and `nsenter` for a genuine host
  shell — with all the danger that implies.
- The `ha` CLI, for driving Home Assistant itself from the same shell.
- The Fedora system itself is persistent, so `dnf install` survives add-on
  updates and resets only when you delete its directory.
- Containers that were running when the add-on stopped come back when it
  starts, whatever restart policy they carry.
- Services from their own systemd unit files, without systemd: `dnf install`
  a package, `systemctl enable --now` it, and it runs and comes back after a
  restart. Drop-ins, `Environment=`, `RuntimeDirectory=`, `Restart=`,
  conditions, dependencies and `Type=forking` behave as the unit file says;
  `journalctl -u` reads the logs.

## Quick start

1. Copy this folder to `/addons/fedora_podman` on the Home Assistant OS
   machine (or add this repository in the add-on store), then *Add-on Store →
   ⋮ → Check for updates*.
2. Install the add-on, then **turn Protection mode off** in its *Info* tab —
   without that the Supervisor drops the permissions Podman needs.
3. Put your SSH public key in `authorized_keys` in the *Configuration* tab.
4. Start it, then `ssh -p 2222 root@homeassistant.local`.

Full instructions, the option reference, an explanation of every capability
the add-on requests, and the limitations are in [DOCS.md](DOCS.md).

## Known-risky parts

Nested containerisation on Home Assistant OS is not a supported configuration
by anyone, and a few things in here are educated engineering rather than
guarantees. The storage-driver selection in particular is done by probing the
kernel at start-up rather than by assumption, and the add-on refuses to start
rather than silently falling back to a driver that would ruin an SD card. See
the *Storage driver* and *Limitations* sections of [DOCS.md](DOCS.md).

## Layout

```
config.yaml     add-on manifest: permissions, mapped paths, options schema
build.yaml      architecture -> Fedora base image mapping
Dockerfile      package installation
rootfs/
  usr/local/bin/entrypoint.sh          option handling, startup, exec sshd
  usr/local/bin/configure-ssh.sh       host keys, authorized_keys, sshd_config
  usr/local/bin/configure-podman.sh    storage driver probe, podman config,
                                       cgroups, host firewall
  usr/local/bin/configure-persistence.sh  persistent /usr /etc /opt /root /var
  usr/local/bin/inspect-runtime.sh     what the Supervisor actually granted
  usr/local/bin/podman-diag            read-only state dump for debugging
  usr/local/bin/addon-reset            queue a reset of storage / system layer
  usr/local/lib/addon-units.sh         reads and runs systemd unit files
  usr/local/bin/systemctl              the systemd replacement built on it
  usr/local/bin/journalctl             reads what those units logged
DOCS.md         user-facing documentation (shown in the add-on UI)
CHANGELOG.md    version history
```
