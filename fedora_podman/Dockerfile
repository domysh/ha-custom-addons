ARG BUILD_FROM
# hadolint ignore=DL3006
FROM ${BUILD_FROM}

# Home Assistant's own base images ship s6-overlay, Fedora does not, and this
# add-on deliberately does not vendor it: there is exactly one long-running
# foreground process to supervise (sshd). Podman containers are supervised by
# podman's own conmon, not by our init, and zombie reaping is handled by
# Docker's tini (see `init: true` in config.yaml). A single entrypoint script
# that sets things up and then exec's sshd is easier to read and to debug from
# the add-on log than a second process supervisor would be.
#
# Package notes:
#   podman, crun, containers-common, netavark, aardvark-dns
#       the container stack itself. crun (not runc) is Fedora's default and
#       handles cgroup v2 - which is what Home Assistant OS boots with.
#   podman-compose
#       chosen over docker-compose: it is a plain client that shells out to
#       podman, so it needs no daemon. The docker-compose v2 plugin talks to a
#       Docker-compatible API socket, which here would mean keeping a
#       `podman system service` process alive - a second daemon to supervise
#       in a container that has no service manager. See DOCS.md if you want it
#       anyway.
#   fuse-overlayfs
#       fallback storage driver, used only if native overlay turns out to be
#       unusable on the mapped storage path (see configure-podman.sh).
#   iptables-nft, iptables-legacy, nftables
#       netavark itself only writes nftables rules (its iptables driver was
#       removed in netavark 2.x), but the Supervisor's Docker owns the
#       iptables FORWARD chain on the host and drops what it does not
#       recognise, so the add-on has to add itself to Docker's DOCKER-USER
#       chain. Which of the two iptables backends Docker uses is not knowable
#       in advance, hence both; `nft` is for reading netavark's own table.
#   jq
#       the add-on options are read from /data/options.json; bashio is not
#       available outside Home Assistant's base images.
#   glibc-langpack-en
#       without a langpack, glibc only has the C locale and interactive shells
#       come up with a broken UTF-8 setup.
#   util-linux-core
#       provides nsenter, used to get a real shell in the host's namespaces
#       (see the host access section of DOCS.md).
#   python3
#       what the service manager is written in (docker-systemctl-replacement,
#       fetched below). podman-compose pulls it in already; it is listed
#       because /usr/bin/systemctl depends on it directly, and an unlisted
#       dependency is one a later cleanup removes. For the same reason it is
#       a dnf protected package (/etc/dnf/protected.d/addon-systemctl.conf):
#       `dnf remove python3` would otherwise take every package scriptlet's
#       systemctl with it.
#
# Package versions are intentionally not pinned: Fedora only ships one version
# of each of these per release, and pinning them would make the image
# un-rebuildable as soon as Fedora pushes a security update. The Fedora
# release itself is pinned in build.yaml, which is the version that matters.
#
# `dnf upgrade` comes first because `dnf install` never touches what the base
# image already ships - openssl, glibc and the rest of what sshd links against.
# The add-on is built on the device, from whatever fedora:45 its Docker pulled
# last, which can be months old; without the upgrade the security fixes Fedora
# has published since then would never land in the image.
RUN dnf upgrade -y --refresh --setopt=install_weak_deps=False --nodocs \
    && dnf install -y --setopt=install_weak_deps=False --nodocs \
        openssh-server \
        openssh-clients \
        podman \
        podman-compose \
        crun \
        containers-common \
        netavark \
        aardvark-dns \
        fuse-overlayfs \
        iptables-nft \
        iptables-legacy \
        nftables \
        jq \
        tzdata \
        glibc-langpack-en \
        shadow-utils \
        procps-ng \
        util-linux-core \
        iproute \
        iputils \
        bind-utils \
        findutils \
        hostname \
        tar \
        gzip \
        xz \
        rsync \
        git \
        curl \
        wget \
        less \
        nano \
        vim-minimal \
        htop \
        bash-completion \
        python3 \
    && dnf clean all \
    && rm -rf /var/cache/dnf

# The `ha` CLI, the same command the official SSH add-on gives you. It is not
# in any Fedora repository: it is a statically linked Go binary published as a
# release asset by home-assistant/cli, so it is fetched here.
#
# Pinned, unlike the dnf packages above: this download is not covered by a
# distribution's update mechanism, so an unpinned "latest" would silently
# change what lands in the image between two rebuilds of the same add-on
# version. Bump it deliberately.
#
# The add-on is built on the target device, so uname -m is the architecture we
# are building for; no BUILD_ARCH plumbing needed.
ARG HA_CLI_VERSION=5.6.0
RUN set -eux; \
    case "$(uname -m)" in \
        aarch64) ha_arch="aarch64" ;; \
        x86_64)  ha_arch="amd64" ;; \
        *) echo "Unsupported architecture for the ha CLI: $(uname -m)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /usr/bin/ha \
        "https://github.com/home-assistant/cli/releases/download/${HA_CLI_VERSION}/ha_${ha_arch}"; \
    chmod 0755 /usr/bin/ha; \
    /usr/bin/ha --help >/dev/null

# The service manager: docker-systemctl-replacement by Guido U. Draheim
# (https://github.com/gdraheim/docker-systemctl-replacement, EUPL-1.2), a
# systemctl that reads unit files and runs them without systemd - which cannot
# run here at all, see /usr/lib/addon-systemctl/systemctl.
#
# It replaces a service manager this add-on used to carry itself, a ~2,400-line
# bash reimplementation in /usr/local/bin. That one worked from a shell, but
# not from rpm: scriptlets run with PATH=/sbin:/bin:/usr/sbin:/usr/bin, never
# saw /usr/local/bin, and so `dnf upgrade netbird` left the old netbird
# running. Moving it to /usr/bin would have fixed that one thing; upstream is
# a maintained, tested implementation of what was being reimplemented, so the
# move was to it instead.
#
# Pinned to a tag and checked against a hash, like the ha CLI above and for
# the same reason, and additionally because it is executed as root by every
# package scriptlet: a changed file has to fail the build, not install. Bump
# the tag and both hashes together, deliberately.
ARG DSR_VERSION=v1.7.1097
ARG DSR_SYSTEMCTL_SHA256=5f5a47f321c7a8881dfd01f774106dc4012d664bee238eada86a7112674fea93
ARG DSR_JOURNALCTL_SHA256=16a52fe484d7c0fca464c82a56de58980440362942482c0d1fbc424e69f8f833
RUN set -eux; \
    base="https://raw.githubusercontent.com/gdraheim/docker-systemctl-replacement/${DSR_VERSION}/files/docker"; \
    mkdir -p /usr/lib/addon-systemctl; \
    cd /usr/lib/addon-systemctl; \
    curl -fsSL -o systemctl3.py "${base}/systemctl3.py"; \
    curl -fsSL -o journalctl3.py "${base}/journalctl3.py"; \
    printf '%s  %s\n' \
        "${DSR_SYSTEMCTL_SHA256}" systemctl3.py \
        "${DSR_JOURNALCTL_SHA256}" journalctl3.py \
        | sha256sum -c -; \
    chmod 0755 systemctl3.py journalctl3.py; \
    python3 systemctl3.py --version >/dev/null

COPY rootfs /

# The entrypoint and the user-facing commands are executed; the configure-*.sh
# files and the boot-units helper are sourced by them. systemctl3.py has to be
# executable as well as the wrappers: journalctl3.py runs it directly.
#
# /usr/bin/systemctl and /usr/bin/journalctl become symlinks to the wrappers.
# systemd is in this image (the package set above pulls it in as a
# dependency), so its real binaries are at those paths now - the check below
# is for a base where it is not. They are moved aside rather than deleted,
# for whoever wants systemd's own offline `systemctl --root=...`, and rpm is
# told not to put them back (/etc/rpm/macros.addon-systemctl). The entrypoint
# re-checks the links on every start, for installs whose persistent /usr
# already has systemd's file in it.
#
# sshd.service and sshd.socket are masked: this add-on is an sshd, and a
# second one would take its port and lock you out. The wrapper refuses
# `systemctl start sshd` by name; the mask is what stops it being started
# along with a target (`systemctl start multi-user.target`, `default`), since
# upstream skips masked units however they are reached.
RUN set -eux; \
    chmod 0755 \
        /usr/local/bin/entrypoint.sh \
        /usr/local/bin/podman-diag \
        /usr/local/bin/addon-reset \
        /usr/lib/addon-systemctl/systemctl \
        /usr/lib/addon-systemctl/journalctl; \
    chmod 0644 \
        /usr/local/bin/configure-podman.sh \
        /usr/local/bin/configure-ssh.sh \
        /usr/local/bin/configure-persistence.sh \
        /usr/local/bin/inspect-runtime.sh \
        /usr/local/lib/addon-boot-units.sh \
        /etc/rpm/macros.addon-systemctl \
        /etc/dnf/protected.d/addon-systemctl.conf; \
    for name in systemctl journalctl; do \
        if [ -e "/usr/bin/${name}" ] && [ ! -L "/usr/bin/${name}" ]; then \
            mkdir -p /usr/lib/addon-systemctl/systemd; \
            mv "/usr/bin/${name}" "/usr/lib/addon-systemctl/systemd/${name}"; \
        fi; \
        ln -sfn "/usr/lib/addon-systemctl/${name}" "/usr/bin/${name}"; \
    done; \
    mkdir -p /etc/systemd/system; \
    ln -sfn /dev/null /etc/systemd/system/sshd.service; \
    ln -sfn /dev/null /etc/systemd/system/sshd.socket; \
    env -i PATH=/usr/sbin:/usr/bin systemctl --version; \
    [ "$(env -i PATH=/usr/sbin:/usr/bin systemctl is-enabled sshd.service)" = masked ]

# Record which units this image arrived with enabled, so the add-on can tell
# them apart from the ones you enable later - the first set is systemd's own
# plumbing (getty@tty1, the systemd-* services, first-boot maintenance) plus
# sshd.service, which the packages' presets linked while the image was being
# built and which nothing here should run. It has to be the last step: every
# dnf above may have enabled something.
RUN bash -c 'source /usr/local/lib/addon-boot-units.sh && boot_units_write_baseline'

LABEL io.hass.type="addon"

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
