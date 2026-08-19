#!/usr/bin/env bash
# Reports how the Supervisor actually started this container.
# Sourced by entrypoint.sh; not meant to be executed on its own.
#
# Several of this add-on's abilities are granted by the manifest but applied
# only when Protection mode is off - the Supervisor checks `not protected`
# before applying full_access, host_pid and the Docker socket mount. When it is
# on they are dropped silently: the manifest still says host_pid: true, nothing
# reports an error, and /proc/1/root simply turns out to be this container's
# own root instead of the host's.
#
# Rather than inferring that from symptoms, this asks the host's Docker what it
# was actually told to do. It only reads (GET), and spawns nothing.

DOCKER_SOCKET="/run/docker.sock"

docker_api_get() {
    curl --silent --show-error --fail --max-time 5 \
        --unix-socket "${DOCKER_SOCKET}" "http://localhost$1" 2>/dev/null
}

# Finds this container by slug: the Supervisor names add-on containers
# addon_<repository>_<slug>, and the repository part is not knowable from in
# here.
find_own_container_id() {
    docker_api_get "/containers/json?all=1" \
        | jq -r '.[] | select(.Names[]? | test("fedora_podman")) | .Id' 2>/dev/null \
        | head -n1
}

report_runtime_state() {
    if [ ! -S "${DOCKER_SOCKET}" ]; then
        warn "The host Docker socket is not present at ${DOCKER_SOCKET}."
        warn "The manifest requests it (docker_api: true), so the Supervisor dropped"
        warn "it - which it only does when Protection mode is ON for this add-on."
        warn "That same switch also drops full device access and the host PID"
        warn "namespace, so /host cannot work either. Turn Protection mode off in"
        warn "the add-on's Info tab and restart."
        return 0
    fi

    local id
    id="$(find_own_container_id)"
    if [ -z "${id}" ]; then
        warn "Could not identify this container through the Docker API; skipping"
        warn "the runtime report. This is only diagnostics - nothing else depends on it."
        return 0
    fi

    local details pid_mode privileged caps
    details="$(docker_api_get "/containers/${id}/json")" || return 0
    pid_mode="$(jq -r '.HostConfig.PidMode // ""' <<<"${details}" 2>/dev/null)"
    privileged="$(jq -r '.HostConfig.Privileged // false' <<<"${details}" 2>/dev/null)"
    caps="$(jq -r '(.HostConfig.CapAdd // []) | join(" ")' <<<"${details}" 2>/dev/null)"

    log "Runtime state as reported by the host Docker:"
    log "  PidMode      : ${pid_mode:-<none>}"
    log "  Privileged   : ${privileged}"
    log "  Added caps   : ${caps:-<none>}"

    # PidMode is the one that decides whether /host can exist at all.
    if [ "${pid_mode}" != "host" ]; then
        warn "The host PID namespace is NOT shared, so PID 1 in here is this add-on's"
        warn "own init and /proc/1/root is this container's root, not the host's."
        warn "The manifest asks for it (host_pid: true), so the Supervisor dropped it:"
        warn "that happens only with Protection mode ON. Turn it off in the add-on's"
        warn "Info tab and restart, and /host will appear."
    fi
}
