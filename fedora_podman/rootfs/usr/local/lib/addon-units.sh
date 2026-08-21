#!/usr/bin/env bash
# Reading and running systemd unit files, without systemd.
# Sourced by the systemctl replacement and by the entrypoint.
#
# Why this exists rather than a real systemd: systemd refuses to run unless it
# is PID 1 (src/core/main.c checks getpid_cached() == 1), and this add-on
# shares the host's PID namespace so that /host and nsenter work - PID 1 in
# here is Home Assistant OS's own systemd, and nothing of ours can ever take
# that place. The choice is between a host filesystem and a real init, and this
# add-on exists for the former.
#
# So the units packages install are read directly. That is the part that
# matters: `dnf install` something, `systemctl enable --now` it, and it runs -
# no translating an ExecStart into a script by hand.
#
# What is supported: Type=simple, exec, notify, idle, oneshot and forking (with
# PIDFile), ExecStartPre/ExecStartPost/ExecStop/ExecReload, Environment,
# EnvironmentFile, WorkingDirectory, User, Restart with RestartSec, WantedBy,
# and template units (foo@bar.service) with %i/%I/%n/%N.
# What is not: socket/timer/path activation, notify readiness protocol
# (Type=notify is run as simple), dependency ordering beyond the boot sequence,
# resource limits, and namespacing directives such as PrivateTmp - which are
# ignored rather than half-applied, since here the add-on is the sandbox.

UNIT_PATHS=(
    /etc/systemd/system
    /run/systemd/system
    /usr/local/lib/systemd/system
    /usr/lib/systemd/system
)
UNIT_WANTS_DIR=/etc/systemd/system/multi-user.target.wants
UNIT_RUN_DIR=/run/addon-units
UNIT_LOG_DIR=/var/log/addon-units
UNIT_LOG_MAX_BYTES=$((5 * 1024 * 1024))

# --- locating units ----------------------------------------------------------

# Adds the implicit .service suffix, the way systemctl does.
unit_full_name() {
    case "$1" in
        *.service | *.target | *.socket | *.timer | *.mount | *.path) printf '%s\n' "$1" ;;
        *) printf '%s.service\n' "$1" ;;
    esac
}

# The file for a unit, honouring the search order above. For an instance
# (foo@bar.service) the template foo@.service is the fallback, as in systemd.
unit_file() {
    local name="$1" dir template
    for dir in "${UNIT_PATHS[@]}"; do
        [ -e "${dir}/${name}" ] && { printf '%s\n' "${dir}/${name}"; return 0; }
    done
    case "${name}" in
        *@*.service)
            template="${name%%@*}@.service"
            for dir in "${UNIT_PATHS[@]}"; do
                [ -e "${dir}/${template}" ] && { printf '%s\n' "${dir}/${template}"; return 0; }
            done
            ;;
    esac
    return 1
}

# --- parsing -----------------------------------------------------------------

# Expands the specifiers a unit may contain. Only the ones that mean something
# without a running systemd are handled; an unknown %x is left alone rather
# than silently blanked, so it shows up in the logs instead of producing a
# command that looks fine and does the wrong thing.
unit_expand() {
    local value="$1" name="$2" instance="${3:-}"
    value="${value//%i/${instance}}"
    value="${value//%I/${instance//-//}}"
    value="${value//%n/${name}}"
    value="${value//%N/${name%.*}}"
    value="${value//%%/%}"
    printf '%s\n' "${value}"
}

# Reads one unit file into U_* globals. Multi-value keys become arrays.
unit_parse() {
    local name="$1" file="$2" instance="" section="" line key value

    case "${name}" in *@*.service) instance="${name#*@}"; instance="${instance%.service}" ;; esac

    U_NAME="${name}"
    U_INSTANCE="${instance}"
    U_DESCRIPTION=""
    U_TYPE=""
    U_EXECSTART=""
    U_EXECSTOP=""
    U_EXECRELOAD=""
    U_WORKDIR=""
    U_USER=""
    U_PIDFILE=""
    U_RESTART=""
    U_RESTARTSEC="1"
    U_TIMEOUTSTOP="30"
    U_WANTEDBY=""
    U_EXECSTARTPRE=()
    U_EXECSTARTPOST=()
    U_ENVIRONMENT=()
    U_ENVIRONMENTFILE=()

    local continued=""
    while IFS= read -r line || [ -n "${line}" ]; do
        # Line continuations: systemd joins a line ending in a backslash with
        # the next one, and unit files in the wild use it for long ExecStart.
        if [ -n "${continued}" ]; then
            line="${continued} ${line#"${line%%[![:space:]]*}"}"
            continued=""
        fi
        case "${line}" in *\\) continued="${line%\\}"; continue ;; esac

        line="${line#"${line%%[![:space:]]*}"}"
        case "${line}" in "" | "#"* | ";"*) continue ;; esac
        case "${line}" in
            "["*"]") section="${line#[}"; section="${section%]}"; continue ;;
        esac

        key="${line%%=*}"
        value="${line#*=}"
        [ "${key}" = "${line}" ] && continue
        key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="$(unit_expand "${value}" "${name}" "${instance}")"

        case "${section}:${key}" in
            Unit:Description) U_DESCRIPTION="${value}" ;;
            Service:Type) U_TYPE="${value}" ;;
            Service:ExecStart) U_EXECSTART="${value}" ;;
            Service:ExecStop) U_EXECSTOP="${value}" ;;
            Service:ExecReload) U_EXECRELOAD="${value}" ;;
            Service:ExecStartPre) U_EXECSTARTPRE+=("${value}") ;;
            Service:ExecStartPost) U_EXECSTARTPOST+=("${value}") ;;
            Service:WorkingDirectory) U_WORKDIR="${value}" ;;
            Service:User) U_USER="${value}" ;;
            Service:PIDFile) U_PIDFILE="${value}" ;;
            Service:Restart) U_RESTART="${value}" ;;
            Service:RestartSec) U_RESTARTSEC="${value%s}" ;;
            Service:TimeoutStopSec) U_TIMEOUTSTOP="${value%s}" ;;
            Service:Environment) U_ENVIRONMENT+=("${value}") ;;
            Service:EnvironmentFile) U_ENVIRONMENTFILE+=("${value}") ;;
            Install:WantedBy) U_WANTEDBY="${value}" ;;
        esac
    done < "${file}"

    [ -n "${U_TYPE}" ] || U_TYPE="simple"
    [ -n "${U_RESTART}" ] || U_RESTART="no"
    # RestartSec can be "100ms" or empty; anything not a plain number becomes
    # one second rather than breaking the sleep in the supervisor loop.
    case "${U_RESTARTSEC}" in ''|*[!0-9]*) U_RESTARTSEC=1 ;; esac
    case "${U_TIMEOUTSTOP}" in ''|*[!0-9]*) U_TIMEOUTSTOP=30 ;; esac
    [ -n "${U_EXECSTART}" ]
}

# --- runtime state -----------------------------------------------------------

unit_state_dir() { printf '%s/%s\n' "${UNIT_RUN_DIR}" "$1"; }
unit_log_file() { printf '%s/%s.log\n' "${UNIT_LOG_DIR}" "$1"; }
unit_child_pidfile() { printf '%s/%s/child.pid\n' "${UNIT_RUN_DIR}" "$1"; }
unit_supervisor_pidfile() { printf '%s/%s/supervisor.pid\n' "${UNIT_RUN_DIR}" "$1"; }
unit_stop_flag() { printf '%s/%s/stop\n' "${UNIT_RUN_DIR}" "$1"; }

unit_pid_alive() {
    local pid
    pid="$(cat "$1" 2>/dev/null)" || return 1
    [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null
}

unit_is_active() { unit_pid_alive "$(unit_child_pidfile "$1")"; }
unit_is_supervised() { unit_pid_alive "$(unit_supervisor_pidfile "$1")"; }

unit_is_enabled() { [ -L "${UNIT_WANTS_DIR}/$1" ]; }

unit_main_pid() {
    local name="$1" pid
    pid="$(cat "$(unit_child_pidfile "${name}")" 2>/dev/null)"
    printf '%s\n' "${pid}"
}

# --- running -----------------------------------------------------------------

# systemd's Exec* lines may start with prefixes: "-" ignore failure, "@" set
# argv[0], "+", "!" and "!!" adjust privileges. None of the privilege ones mean
# anything here (everything runs as root in a container that is already the
# sandbox), so they are stripped rather than honoured.
unit_strip_exec_prefix() {
    local cmd="$1"
    while :; do
        case "${cmd}" in
            [-@+!]*) cmd="${cmd#?}" ;;
            *) break ;;
        esac
    done
    printf '%s\n' "${cmd}"
}

unit_exec_ignores_failure() {
    case "$1" in -*) return 0 ;; *) return 1 ;; esac
}

# Applies Environment= and EnvironmentFile= to the *current* shell. Called
# inside the subshell that is about to become the service, never in the
# supervisor itself.
unit_prepare_environment() {
    local env_line file
    for env_line in "${U_ENVIRONMENT[@]}"; do
        export "${env_line?}" 2>/dev/null || true
    done
    for file in "${U_ENVIRONMENTFILE[@]}"; do
        # A leading "-" means "skip if missing", which is common for the
        # /etc/sysconfig/<name> files a package may or may not ship.
        file="${file#-}"
        if [ -r "${file}" ]; then
            set -a
            # shellcheck disable=SC1090
            . "${file}"
            set +a
        fi
    done
    [ -n "${U_WORKDIR}" ] && cd "${U_WORKDIR}" 2>/dev/null
    return 0
}

# Replaces the calling shell with the command. It has to be the last thing that
# subshell does, and it has to be an exec: otherwise the recorded PID is a
# shell wrapping the service rather than the service itself, and everything
# downstream is wrong - `systemctl stop` signals the wrapper and leaves the
# daemon running orphaned, and the supervisor sees the wrapper exit rather than
# the service. `bash -c` with a single simple command execs it in turn, so no
# extra process is left in between either.
#
# Note that systemd does not use a shell for Exec* lines while this does: it is
# more permissive, not less, and the difference only shows with shell
# metacharacters, which a unit file has no reason to contain.
unit_exec_in_place() {
    local cmd
    cmd="$(unit_strip_exec_prefix "$1")"
    if [ -n "${U_USER}" ] && [ "${U_USER}" != "root" ]; then
        exec setpriv --reuid "${U_USER}" --regid "${U_USER}" --init-groups bash -c "${cmd}"
    fi
    exec bash -c "${cmd}"
}

# For the one-shot Exec* lines - Pre, Post, Stop, Reload - which are waited for
# rather than supervised, so their PID does not matter.
unit_run_command() {
    (
        unit_prepare_environment
        unit_exec_in_place "$1"
    )
}

unit_rotate_log() {
    local file="$1" size
    size="$(stat -c '%s' "${file}" 2>/dev/null)" || return 0
    [ "${size}" -gt "${UNIT_LOG_MAX_BYTES}" ] || return 0
    mv -f "${file}" "${file}.1" 2>/dev/null || true
}

unit_should_restart() {
    local policy="$1" status="$2"
    case "${policy}" in
        always | unless-stopped) return 0 ;;
        on-failure | on-abnormal) [ "${status}" != "0" ] ;;
        *) return 1 ;;
    esac
}

# Runs one unit and keeps it running according to Restart=. Blocks; callers
# background it. Output is tagged and written both to the unit's log file and
# to this process's stdout, which is the add-on log when the entrypoint started
# it.
unit_supervise() {
    local name="$1"
    local state log stop_flag delay started ended status cmd

    state="$(unit_state_dir "${name}")"
    log="$(unit_log_file "${name}")"
    stop_flag="$(unit_stop_flag "${name}")"

    mkdir -p "${state}" "${UNIT_LOG_DIR}"
    rm -f "${stop_flag}"
    printf '%s\n' "$$" > "$(unit_supervisor_pidfile "${name}")"

    for cmd in "${U_EXECSTARTPRE[@]}"; do
        if ! unit_run_command "${cmd}" >> "${log}" 2>&1 && ! unit_exec_ignores_failure "${cmd}"; then
            printf '[%s] ExecStartPre failed, not starting\n' "${name}" | tee -a "${log}"
            rm -f "$(unit_supervisor_pidfile "${name}")"
            return 1
        fi
    done

    delay="${U_RESTARTSEC}"
    while :; do
        [ -e "${stop_flag}" ] && break
        unit_rotate_log "${log}"
        started="$(date '+%s')"

        # Job control on purpose: it puts each background job in a process
        # group of its own, so stopping the unit can signal the whole group -
        # the service and whatever it spawned - the way systemd signals a
        # cgroup. Without it the group is the supervisor's own, and signalling
        # it would kill the supervisor along with the service.
        set -m
        {
            (
                # Job control off again inside the child. The process group was
                # assigned by the parent when it started this job and does not
                # change, but with job control on bash will not replace itself
                # with the command - it forks instead, and the PID recorded
                # below would be a shell wrapping the service rather than the
                # service.
                set +m
                unit_prepare_environment
                unit_exec_in_place "${U_EXECSTART}"
            ) &
            printf '%s\n' "$!" > "$(unit_child_pidfile "${name}")"
            wait "$!"
        } 2>&1 | sed -u "s/^/[${name}] /" | tee -a "${log}"
        set +m
        status="${PIPESTATUS[0]}"

        rm -f "$(unit_child_pidfile "${name}")"
        [ -e "${stop_flag}" ] && break

        # Type=oneshot is expected to exit; that is not a failure to react to.
        [ "${U_TYPE}" = "oneshot" ] && break

        if ! unit_should_restart "${U_RESTART}" "${status}"; then
            printf '[%s] exited with status %s; Restart=%s, so it stays stopped\n' \
                "${name}" "${status}" "${U_RESTART}" | tee -a "${log}"
            break
        fi

        ended="$(date '+%s')"
        # A unit that ran for a while is healthy; only a crash loop gets the
        # growing delay, so a service that dies once after a week does not then
        # wait a minute to come back.
        [ "$((ended - started))" -ge 60 ] && delay="${U_RESTARTSEC}"

        printf '[%s] exited with status %s; restarting in %ss\n' "${name}" "${status}" "${delay}" \
            | tee -a "${log}"
        sleep "${delay}"
        delay=$((delay * 2))
        [ "${delay}" -gt 60 ] && delay=60
    done

    for cmd in "${U_EXECSTARTPOST[@]}"; do
        unit_run_command "${cmd}" >> "${log}" 2>&1 || true
    done

    rm -f "$(unit_supervisor_pidfile "${name}")" "${stop_flag}"
}

# --- boot --------------------------------------------------------------------

# log/warn belong to the entrypoint; when this library is used from systemctl
# they are not there, and a service manager that dies because it tried to log
# would be a poor one.
if ! declare -F log >/dev/null 2>&1; then
    log() { printf '%s\n' "$*"; }
fi
if ! declare -F warn >/dev/null 2>&1; then
    warn() { printf 'WARNING: %s\n' "$*" >&2; }
fi

# Starts everything enabled, which is what `systemctl enable` linked into
# multi-user.target.wants. That directory is on /etc, which this add-on keeps
# on its persistent layer, so what you enabled once stays enabled across
# restarts and updates - the point of enabling something.
unit_start_enabled() {
    local link name file started=()

    mkdir -p "${UNIT_RUN_DIR}" "${UNIT_LOG_DIR}"

    # Worth saying once, because it is confusing to run into: installing a
    # package that ships a unit file often pulls the systemd package in for its
    # scriptlets, so a real systemctl can appear on disk. It cannot run here -
    # nothing can be PID 1 - and /usr/local/bin comes first in PATH, so the
    # replacement is what answers. Anyone who calls the real one by its full
    # path gets systemd's own refusal, which is not a fault in this add-on.
    if [ -x /usr/bin/systemctl ]; then
        log "The systemd package is installed, but systemd cannot run in an add-on."
        log "'systemctl' resolves to the replacement in /usr/local/bin, which runs units."
    fi
    [ -d "${UNIT_WANTS_DIR}" ] || return 0

    for link in "${UNIT_WANTS_DIR}"/*; do
        [ -e "${link}" ] || continue
        name="${link##*/}"

        if ! file="$(unit_file "${name}")"; then
            warn "Enabled unit ${name} has no unit file any more; skipping it."
            warn "Was its package removed? 'systemctl disable ${name}' clears this."
            continue
        fi
        if ! unit_parse "${name}" "${file}"; then
            warn "Enabled unit ${name} has no ExecStart; skipping it."
            continue
        fi

        unit_supervise "${name}" &
        started+=("${name}")
    done

    if [ "${#started[@]}" -gt 0 ]; then
        log "Started enabled units: ${started[*]}"
        log "Manage them with systemctl; their logs are in ${UNIT_LOG_DIR}"
    fi
}
