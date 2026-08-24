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
#       (see the host access section of DOCS.md), and setpriv, which runs a
#       unit's ExecStart as its User= when it asks for one.
#
# Package versions are intentionally not pinned: Fedora only ships one version
# of each of these per release, and pinning them would make the image
# un-rebuildable as soon as Fedora pushes a security update. The Fedora
# release itself is pinned in build.yaml, which is the version that matters.
RUN dnf install -y --setopt=install_weak_deps=False --nodocs \
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
ARG HA_CLI_VERSION=5.3.1
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

COPY rootfs /

# The entrypoint and the user-facing commands are executed; the configure-*.sh
# files and the unit library are sourced by them. The systemctl and journalctl
# here are not systemd's - neither systemd nor journald can run in this add-on
# at all, see addon-units.sh - but replacements that read the unit files
# packages install and the logs those units write. /usr/local/bin precedes
# /usr/bin in PATH, so they answer even when a package pulls the real systemd
# in for its scriptlets; they deliberately do not hand over to it, because it
# could only refuse.
RUN chmod 0755 \
        /usr/local/bin/entrypoint.sh \
        /usr/local/bin/podman-diag \
        /usr/local/bin/addon-reset \
        /usr/local/bin/systemctl \
        /usr/local/bin/journalctl \
    && chmod 0644 \
        /usr/local/bin/configure-podman.sh \
        /usr/local/bin/configure-ssh.sh \
        /usr/local/bin/configure-persistence.sh \
        /usr/local/bin/inspect-runtime.sh \
        /usr/local/lib/addon-units.sh

LABEL io.hass.type="addon"

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
