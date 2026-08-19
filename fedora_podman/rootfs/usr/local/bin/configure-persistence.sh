#!/usr/bin/env bash
# Persistence of the Fedora system itself.
# Sourced by entrypoint.sh; not meant to be executed on its own.
#
# Without this, everything outside the mapped host paths lives in the
# container's writable layer, which the Supervisor throws away whenever the
# add-on is updated or rebuilt - so a `dnf install` done over SSH is gone at
# the next update. That makes the shell feel disposable in a way a root shell
# on a real machine is not, which is the opposite of the point of this add-on.
#
# So this is not optional and has no switch: the directories a package
# installation actually touches are overlay-mounted with their upper layer on a
# mapped path. Writes land in that upper layer and survive updates; the image
# underneath stays the read-only lower layer. Resetting means deleting that one
# directory, and nothing else resets it - not an update, not a rebuild.

# The set of directories a dnf transaction writes to. /var matters as much as
# /usr: the RPM database lives in /var/lib/rpm, and without it dnf would lose
# track of everything installed the moment the container restarts.
PERSIST_DIRS=(/usr /etc /opt /root /var)

# Guards against the one genuinely dangerous scenario: the add-on is rebuilt on
# a newer base image, and a stale upper layer keeps shadowing files that the
# new image updated - old libraries over a new glibc, for instance. Fedora's
# major version is a coarse but reliable signal for that.
#
# Since persistence is now the normal mode of operation, refusing to mount and
# carrying on would quietly turn the add-on into the non-persistent thing it
# used to be. The stale layer is moved aside instead: persistence stays active
# on a fresh layer, and the old one is still on disk to salvage packages or
# configuration from. Deleting it is left to whoever looks at it.
prepare_layer_for_this_image() {
    local base="$1"
    local marker="${base}/.fedora-version"
    local current stored retired

    # VERSION_ID is unquoted in Fedora's os-release but quoted in other
    # distributions', so the quotes are stripped rather than assumed absent.
    current="$(sed -n 's/^VERSION_ID=//p' "${OS_RELEASE_FILE:-/etc/os-release}" 2>/dev/null | tr -d '"')"
    [ -n "${current}" ] || return 0

    if [ ! -f "${marker}" ]; then
        # Either a first start, or a layer from before the marker existed. An
        # empty directory is a first start; anything else is old enough to be
        # worth treating as a mismatch, since its Fedora version is unknown.
        if [ -z "$(ls -A "${base}" 2>/dev/null)" ]; then
            printf '%s\n' "${current}" > "${marker}"
            return 0
        fi
        stored="unknown"
    else
        stored="$(cat "${marker}" 2>/dev/null)"
        [ "${stored}" != "${current}" ] || return 0
    fi

    retired="${base}.fedora-${stored}.$(date '+%Y%m%d%H%M%S')"
    warn "The persisted system layer was created on Fedora ${stored}, but this image"
    warn "is Fedora ${current}. Reusing it would let old files shadow the ones the new"
    warn "image updated, which breaks in confusing ways."
    if mv "${base}" "${retired}" 2>/dev/null; then
        warn "Moved it aside to ${retired} and started a fresh one, so persistence"
        warn "stays active. Packages you had installed by hand are NOT carried over:"
        warn "reinstall them with dnf, then delete ${retired} when you are done with it."
    else
        warn "Could not move it aside, so nothing is persisted this start: anything"
        warn "installed with dnf will be lost on the next add-on update."
        warn "Fix it by stopping the add-on and deleting ${base}, then starting it again."
        return 1
    fi

    mkdir -p "${base}"
    printf '%s\n' "${current}" > "${marker}"
    return 0
}

setup_persistent_system() {
    local base="$1"

    mkdir -p "${base}"

    # Reuses the storage probe: the upper layer has the same requirement as
    # Podman's graph root, namely a filesystem the kernel will accept as an
    # overlay upperdir.
    if ! test_native_overlay "${base}"; then
        warn "Cannot persist the system: ${base} does not support overlay mounts."
        warn "The add-on still works, but anything installed with dnf over SSH is"
        warn "lost on the next add-on update. This normally means Protection mode is"
        warn "on (the add-on then loses the capability it needs to mount), or that"
        warn "/config is not really a mapped host path - see the add-on log above."
        return 0
    fi

    prepare_layer_for_this_image "${base}" || return 0

    local dir name upper work mounted=()
    for dir in "${PERSIST_DIRS[@]}"; do
        name="${dir//\//_}"
        upper="${base}/upper${name}"
        work="${base}/work${name}"
        # workdir must sit on the same filesystem as upperdir, hence both here.
        mkdir -p "${upper}" "${work}"

        if mount -t overlay "persist${name}" \
            -o "lowerdir=${dir},upperdir=${upper},workdir=${work}" "${dir}" 2>/dev/null
        then
            mounted+=("${dir}")
        else
            warn "Could not make ${dir} persistent; changes there will be lost on update."
        fi
    done

    if [ "${#mounted[@]}" -gt 0 ]; then
        log "System persistence active on: ${mounted[*]} (upper layer in ${base})"
        log "Packages installed with dnf over SSH survive add-on updates."
    fi
}
