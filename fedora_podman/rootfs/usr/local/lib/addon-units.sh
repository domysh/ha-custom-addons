#!/usr/bin/env bash
# Reading and running systemd unit files, without systemd.
# Sourced by the systemctl replacement, by journalctl and by the entrypoint.
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
# WHAT IS HONOURED
#   [Unit]     Description, Documentation, After, Before, Requires, Requisite,
#              Wants, BindsTo, PartOf, Conflicts, Condition*/Assert* (path,
#              file, directory, user, virtualisation, kernel command line, host)
#   [Service]  Type=simple|exec|idle|notify|oneshot|forking (forking needs
#              PIDFile), ExecCondition, ExecStartPre, ExecStart (several for
#              oneshot), ExecStartPost, ExecReload, ExecStop, ExecStopPost,
#              Environment (quoted, several per line), EnvironmentFile (with
#              the leading "-"), WorkingDirectory, RootDirectory, User, Group,
#              SupplementaryGroups, UMask, Nice, OOMScoreAdjust, Limit*,
#              PIDFile, Restart with RestartSec, SuccessExitStatus,
#              RestartPreventExitStatus, RestartForceExitStatus,
#              RemainAfterExit, TimeoutStartSec, TimeoutStopSec, KillMode,
#              KillSignal, FinalKillSignal, SendSIGKILL, RuntimeDirectory,
#              StateDirectory, CacheDirectory, LogsDirectory,
#              ConfigurationDirectory and their *Mode/RuntimeDirectoryPreserve,
#              StandardOutput/StandardError (journal, null, tty, file:,
#              append:, inherit), SyslogIdentifier
#   [Install]  WantedBy, RequiredBy, Also, Alias
#   Files      drop-ins (<unit>.d/*.conf in every unit directory, template
#              drop-ins included), masking (a symlink to /dev/null), line
#              continuations, template units (foo@bar.service), and the
#              specifiers %i %I %n %N %p %P %f %j %t %S %C %L %E %T %V %h %u
#              %U %H %m %b %%
#
# WHAT IS NOT, and is ignored rather than half-applied
#   Socket, timer, path and D-Bus activation - there is no bus and no event
#   loop here, so a unit that is only ever started by one of those is never
#   started. Targets are synchronisation points with nothing to execute, so
#   they are inert: pulling one in starts the services *it* wants, not the
#   target itself.
#
#   The Type=notify readiness protocol. Such a unit is run as simple and
#   NOTIFY_SOCKET is deliberately left unset, which sd_notify() treats as "no
#   manager listening" and turns into a no-op - the daemon runs, it just has
#   nowhere to report readiness to.
#
#   The sandboxing directives - PrivateTmp, ProtectSystem, NoNewPrivileges,
#   DynamicUser, capability sets and the rest. In here the add-on *is* the
#   sandbox, and a half-applied confinement is worse than an honest none.
#
#   Resource control (CPUQuota, MemoryMax and the other cgroup knobs): the
#   add-on's own cgroup is the Supervisor's, and carving it up per service is
#   not something to do behind the user's back. Limit* is applied because it is
#   per-process (setrlimit) and needs no cgroup.

# Paths, overridable only so this can be exercised outside a container; nothing
# sets them in the add-on.
: "${UNIT_ETC_DIR:=/etc/systemd/system}"
: "${UNIT_RUN_DIR:=/run/addon-units}"
: "${UNIT_LOG_DIR:=/var/log/addon-units}"
: "${UNIT_STATE_ROOT:=/var/lib}"
: "${UNIT_CACHE_ROOT:=/var/cache}"
: "${UNIT_CONFIG_ROOT:=/etc}"
: "${UNIT_RUNTIME_ROOT:=/run}"
: "${UNIT_LOG_MAX_BYTES:=$((5 * 1024 * 1024))}"
# TimeoutStopSec=infinity would mean "wait for ever", which in an add-on whose
# container is killed ten seconds into a stop is a promise nothing can keep.
: "${UNIT_TIMEOUT_CAP:=900}"

# The search order systemd itself uses, most specific first. An array cannot be
# passed through the environment, so the override is a colon-separated list -
# which is only ever set when exercising this outside a container.
if [ -n "${UNIT_SEARCH_PATH:-}" ]; then
    IFS=: read -r -a UNIT_PATHS <<< "${UNIT_SEARCH_PATH}"
elif [ -z "${UNIT_PATHS+set}" ]; then
    UNIT_PATHS=(
        "${UNIT_ETC_DIR}"
        /run/systemd/system
        /usr/local/lib/systemd/system
        /usr/lib/systemd/system
    )
fi

# Where `enable` links a unit when its [Install] section says nothing.
UNIT_DEFAULT_TARGET="multi-user.target"
UNIT_WANTS_DIR="${UNIT_ETC_DIR}/${UNIT_DEFAULT_TARGET}.wants"

# --- locating units ----------------------------------------------------------

# Adds the implicit .service suffix, the way systemctl does.
unit_full_name() {
    case "$1" in
        *.service | *.target | *.socket | *.timer | *.mount | *.path | *.slice | *.device)
            printf '%s\n' "$1" ;;
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

# `systemctl mask` points a unit at /dev/null, and systemd then refuses to
# start it however it is reached. Same here.
unit_is_masked() {
    local file
    file="$(unit_file "$1")" || return 1
    [ -L "${file}" ] && [ "$(readlink -f "${file}" 2>/dev/null)" = "/dev/null" ]
}

# Drop-in files for a unit, in the order they must be applied: systemd sorts
# them by file name, and a later file wins. The template's drop-ins apply to
# every instance, so both directories are collected for foo@bar.service.
unit_dropins() {
    local name="$1" dir template files=() f
    for dir in "${UNIT_PATHS[@]}"; do
        for f in "${dir}/${name}.d"/*.conf; do
            [ -e "${f}" ] && files+=("${f}")
        done
    done
    case "${name}" in
        *@*.service)
            template="${name%%@*}@.service"
            for dir in "${UNIT_PATHS[@]}"; do
                for f in "${dir}/${template}.d"/*.conf; do
                    [ -e "${f}" ] && files+=("${f}")
                done
            done
            ;;
    esac
    [ "${#files[@]}" -gt 0 ] || return 0
    for f in "${files[@]}"; do
        printf '%s\t%s\n' "${f##*/}" "${f}"
    done | sort -k1,1 | cut -f2-
}

# --- strings -----------------------------------------------------------------

# Splits a value the way systemd does: unquoted whitespace separates words,
# "..." and '...' quote (the quotes are removed), and inside double quotes a
# backslash escapes the next character. One word per line of output.
#
# This is what makes Environment="PORT=41641" work. Sourcing or exporting the
# raw value instead leaves the quotes in the variable *name*, the assignment
# fails, and the unit starts with an empty ${PORT} - which is how this was
# found: tailscaled refusing "--port=" with "can't be the empty string".
unit_split_words() {
    local s="$1" out="" started="" quote="" esc="" c i n
    n="${#s}"
    for (( i = 0; i < n; i++ )); do
        c="${s:i:1}"
        if [ -n "${esc}" ]; then out+="${c}"; esc=""; continue; fi
        case "${quote}" in
            '"')
                case "${c}" in
                    '\') esc=1 ;;
                    '"') quote="" ;;
                    *) out+="${c}" ;;
                esac
                ;;
            "'")
                case "${c}" in
                    "'") quote="" ;;
                    *) out+="${c}" ;;
                esac
                ;;
            *)
                case "${c}" in
                    [[:space:]])
                        if [ -n "${started}" ]; then printf '%s\n' "${out}"; out=""; started=""; fi
                        ;;
                    '"' | "'") quote="${c}"; started=1 ;;
                    '\') esc=1; started=1 ;;
                    *) out+="${c}"; started=1 ;;
                esac
                ;;
        esac
    done
    [ -n "${started}" ] && printf '%s\n' "${out}"
    return 0
}

# systemd time spans: "5" (seconds), "100ms", "30s", "5min", "1min 30s",
# "infinity". Returns whole seconds, because everything here waits in `sleep`
# and in whole-second loops.
unit_time_seconds() {
    local spec="$1" total=0 ms=0 token number suffix
    spec="${spec,,}"
    case "${spec}" in
        infinity | "") printf '%s\n' "${UNIT_TIMEOUT_CAP}"; return 0 ;;
    esac
    # "1min30s" as well as "1min 30s": a digit after a letter starts a new token.
    spec="$(printf '%s' "${spec}" | sed -E 's/([a-z])([0-9])/\1 \2/g')"
    for token in ${spec}; do
        number="${token%%[!0-9]*}"
        suffix="${token#"${number}"}"
        [ -n "${number}" ] || continue
        case "${suffix}" in
            us | usec) ms=$((ms + number / 1000)) ;;
            ms | msec) ms=$((ms + number)) ;;
            "" | s | sec | seconds | second) total=$((total + number)) ;;
            m | min | minute | minutes) total=$((total + number * 60)) ;;
            h | hr | hour | hours) total=$((total + number * 3600)) ;;
            d | day | days) total=$((total + number * 86400)) ;;
            w | week | weeks) total=$((total + number * 604800)) ;;
            *) total=$((total + number)) ;;
        esac
    done
    # Sub-second values become one second rather than zero: a RestartSec of
    # 100ms that rounded to 0 would turn a crash loop into a busy loop.
    [ "${ms}" -gt 0 ] && [ "$((ms / 1000))" -eq 0 ] && total=$((total + 1))
    [ "${ms}" -ge 1000 ] && total=$((total + ms / 1000))
    [ "${total}" -gt "${UNIT_TIMEOUT_CAP}" ] && total="${UNIT_TIMEOUT_CAP}"
    printf '%s\n' "${total}"
}

# Expands the specifiers a unit may contain. Only the ones that mean something
# without a running systemd are handled; an unknown %x is left alone rather
# than silently blanked, so it shows up in the logs instead of producing a
# command that looks fine and does the wrong thing.
unit_expand() {
    local value="$1" name="$2" instance="${3:-}"
    local prefix="${name%%@*}" bare="${name%.*}"

    case "${value}" in *%*) ;; *) printf '%s\n' "${value}"; return 0 ;; esac

    value="${value//%i/${instance}}"
    value="${value//%I/${instance//-//}}"
    value="${value//%n/${name}}"
    value="${value//%N/${bare}}"
    value="${value//%p/${prefix}}"
    value="${value//%P/${prefix//-//}}"
    value="${value//%j/${bare##*-}}"
    value="${value//%f//${instance//-//}}"
    # Directories. These are the ones a unit uses together with
    # RuntimeDirectory= and friends, so they have to agree with what this
    # library creates below.
    value="${value//%t/${UNIT_RUNTIME_ROOT}}"
    value="${value//%S/${UNIT_STATE_ROOT}}"
    value="${value//%C/${UNIT_CACHE_ROOT}}"
    value="${value//%L/${UNIT_LOG_DIR%/*}}"
    value="${value//%E/${UNIT_CONFIG_ROOT}}"
    value="${value//%T/\/tmp}"
    value="${value//%V/\/var\/tmp}"
    value="${value//%h/${HOME:-/root}}"
    value="${value//%u/${USER:-root}}"
    value="${value//%U/$(id -u 2>/dev/null || echo 0)}"
    value="${value//%H/$(hostname 2>/dev/null || echo localhost)}"
    value="${value//%m/$(cat /etc/machine-id 2>/dev/null || echo 0)}"
    value="${value//%b/$(tr -d '-' < /proc/sys/kernel/random/boot_id 2>/dev/null || echo 0)}"
    value="${value//%%/%}"
    printf '%s\n' "${value}"
}

# --- parsing -----------------------------------------------------------------

unit_reset() {
    U_NAME=""; U_INSTANCE=""; U_FILE=""
    U_DESCRIPTION=""; U_DOCUMENTATION=""
    U_AFTER=(); U_BEFORE=(); U_REQUIRES=(); U_REQUISITE=(); U_WANTS=()
    U_BINDSTO=(); U_PARTOF=(); U_CONFLICTS=(); U_CONDITIONS=(); U_ASSERTS=()
    U_TYPE=""; U_EXECSTART=(); U_EXECSTARTPRE=(); U_EXECSTARTPOST=()
    U_EXECCONDITION=(); U_EXECSTOP=(); U_EXECSTOPPOST=(); U_EXECRELOAD=()
    U_ENVIRONMENT=(); U_ENVIRONMENTFILE=()
    U_WORKDIR=""; U_ROOTDIR=""; U_USER=""; U_GROUP=""; U_SUPGROUPS=""
    U_UMASK=""; U_NICE=""; U_OOM=""; U_LIMITS=()
    U_PIDFILE=""; U_RESTART=""; U_RESTARTSEC="100ms"
    U_SUCCESSEXIT=(); U_RESTARTPREVENT=(); U_RESTARTFORCE=()
    U_REMAINAFTEREXIT="no"
    U_TIMEOUTSTART="90"; U_TIMEOUTSTOP="30"
    U_KILLMODE="control-group"; U_KILLSIGNAL="TERM"; U_FINALKILLSIGNAL="KILL"
    U_SENDSIGKILL="yes"
    U_RUNTIMEDIR=(); U_STATEDIR=(); U_CACHEDIR=(); U_LOGSDIR=(); U_CONFDIR=()
    U_RUNTIMEDIRMODE="0755"; U_STATEDIRMODE="0755"; U_CACHEDIRMODE="0755"
    U_LOGSDIRMODE="0755"; U_CONFDIRMODE="0755"; U_RUNTIMEDIRPRESERVE="no"
    U_STDOUT=""; U_STDERR=""; U_SYSLOGID=""
    U_WANTEDBY=(); U_REQUIREDBY=(); U_ALSO=(); U_ALIAS=()
    U_DROPINS=()
}

# systemd's rule for a list-valued key: repeating it appends, and assigning it
# an empty value clears what came before. That second half is what makes a
# drop-in able to replace an ExecStart instead of adding a second one, which is
# the single most common thing drop-ins are used for.
unit_list_assign() {
    local -n _list="$1"
    local value="$2"
    if [ -z "${value}" ]; then _list=(); return 0; fi
    _list+=("${value}")
}

# Reads one file into the U_* globals. Called for the unit file first and then
# for each drop-in, which is why it does not reset anything itself.
unit_parse_file() {
    local file="$1" name="$2" instance="$3"
    local section="" line key value continued="" word

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
            Unit:Documentation) U_DOCUMENTATION="${value}" ;;
            Unit:After) unit_list_assign U_AFTER "${value}" ;;
            Unit:Before) unit_list_assign U_BEFORE "${value}" ;;
            Unit:Requires) unit_list_assign U_REQUIRES "${value}" ;;
            Unit:Requisite) unit_list_assign U_REQUISITE "${value}" ;;
            Unit:Wants) unit_list_assign U_WANTS "${value}" ;;
            Unit:BindsTo) unit_list_assign U_BINDSTO "${value}" ;;
            Unit:PartOf) unit_list_assign U_PARTOF "${value}" ;;
            Unit:Conflicts) unit_list_assign U_CONFLICTS "${value}" ;;
            Unit:Condition*) unit_list_assign U_CONDITIONS "${key#Condition}=${value}" ;;
            Unit:Assert*) unit_list_assign U_ASSERTS "${key#Assert}=${value}" ;;

            Service:Type) U_TYPE="${value}" ;;
            Service:ExecCondition) unit_list_assign U_EXECCONDITION "${value}" ;;
            Service:ExecStartPre) unit_list_assign U_EXECSTARTPRE "${value}" ;;
            Service:ExecStart) unit_list_assign U_EXECSTART "${value}" ;;
            Service:ExecStartPost) unit_list_assign U_EXECSTARTPOST "${value}" ;;
            Service:ExecReload) unit_list_assign U_EXECRELOAD "${value}" ;;
            Service:ExecStop) unit_list_assign U_EXECSTOP "${value}" ;;
            Service:ExecStopPost) unit_list_assign U_EXECSTOPPOST "${value}" ;;
            Service:Environment)
                if [ -z "${value}" ]; then
                    U_ENVIRONMENT=()
                else
                    while IFS= read -r word; do
                        case "${word}" in *=*) U_ENVIRONMENT+=("${word}") ;; esac
                    done < <(unit_split_words "${value}")
                fi
                ;;
            Service:EnvironmentFile) unit_list_assign U_ENVIRONMENTFILE "${value}" ;;
            Service:WorkingDirectory) U_WORKDIR="${value}" ;;
            Service:RootDirectory) U_ROOTDIR="${value}" ;;
            Service:User) U_USER="${value}" ;;
            Service:Group) U_GROUP="${value}" ;;
            Service:SupplementaryGroups) U_SUPGROUPS="${value}" ;;
            Service:UMask) U_UMASK="${value}" ;;
            Service:Nice) U_NICE="${value}" ;;
            Service:OOMScoreAdjust) U_OOM="${value}" ;;
            Service:Limit*) unit_list_assign U_LIMITS "${key#Limit}=${value}" ;;
            Service:PIDFile) U_PIDFILE="${value}" ;;
            Service:Restart) U_RESTART="${value}" ;;
            Service:RestartSec) U_RESTARTSEC="${value}" ;;
            Service:SuccessExitStatus) unit_list_assign U_SUCCESSEXIT "${value}" ;;
            Service:RestartPreventExitStatus) unit_list_assign U_RESTARTPREVENT "${value}" ;;
            Service:RestartForceExitStatus) unit_list_assign U_RESTARTFORCE "${value}" ;;
            Service:RemainAfterExit) U_REMAINAFTEREXIT="${value}" ;;
            Service:TimeoutStartSec) U_TIMEOUTSTART="${value}" ;;
            Service:TimeoutStopSec) U_TIMEOUTSTOP="${value}" ;;
            Service:TimeoutSec) U_TIMEOUTSTART="${value}"; U_TIMEOUTSTOP="${value}" ;;
            Service:KillMode) U_KILLMODE="${value}" ;;
            Service:KillSignal) U_KILLSIGNAL="${value}" ;;
            Service:FinalKillSignal) U_FINALKILLSIGNAL="${value}" ;;
            Service:SendSIGKILL) U_SENDSIGKILL="${value}" ;;
            Service:RuntimeDirectory) unit_list_assign U_RUNTIMEDIR "${value}" ;;
            Service:StateDirectory) unit_list_assign U_STATEDIR "${value}" ;;
            Service:CacheDirectory) unit_list_assign U_CACHEDIR "${value}" ;;
            Service:LogsDirectory) unit_list_assign U_LOGSDIR "${value}" ;;
            Service:ConfigurationDirectory) unit_list_assign U_CONFDIR "${value}" ;;
            Service:RuntimeDirectoryMode) U_RUNTIMEDIRMODE="${value}" ;;
            Service:StateDirectoryMode) U_STATEDIRMODE="${value}" ;;
            Service:CacheDirectoryMode) U_CACHEDIRMODE="${value}" ;;
            Service:LogsDirectoryMode) U_LOGSDIRMODE="${value}" ;;
            Service:ConfigurationDirectoryMode) U_CONFDIRMODE="${value}" ;;
            Service:RuntimeDirectoryPreserve) U_RUNTIMEDIRPRESERVE="${value}" ;;
            Service:StandardOutput) U_STDOUT="${value}" ;;
            Service:StandardError) U_STDERR="${value}" ;;
            Service:SyslogIdentifier) U_SYSLOGID="${value}" ;;

            Install:WantedBy) unit_list_assign U_WANTEDBY "${value}" ;;
            Install:RequiredBy) unit_list_assign U_REQUIREDBY "${value}" ;;
            Install:Also) unit_list_assign U_ALSO "${value}" ;;
            Install:Alias) unit_list_assign U_ALIAS "${value}" ;;
        esac
    done < "${file}"
    return 0
}

# Reads a unit and everything that overrides it into the U_* globals. Fails
# only when the unit cannot be run at all - no ExecStart, or masked - because
# every caller has to decide what to say about that itself.
unit_parse() {
    local name="$1" file="$2" instance="" dropin

    case "${name}" in *@*.service) instance="${name#*@}"; instance="${instance%.service}" ;; esac

    unit_reset
    U_NAME="${name}"
    U_INSTANCE="${instance}"
    U_FILE="${file}"

    unit_parse_file "${file}" "${name}" "${instance}"
    while IFS= read -r dropin; do
        [ -n "${dropin}" ] || continue
        unit_parse_file "${dropin}" "${name}" "${instance}"
        U_DROPINS+=("${dropin}")
    done < <(unit_dropins "${name}")

    [ -n "${U_TYPE}" ] || {
        # systemd's default is "simple", except with no ExecStart and only
        # ExecStop-like lines, which is not something to guess at here.
        U_TYPE="simple"
    }
    [ -n "${U_RESTART}" ] || U_RESTART="no"
    U_RESTARTSEC="$(unit_time_seconds "${U_RESTARTSEC}")"
    U_TIMEOUTSTART="$(unit_time_seconds "${U_TIMEOUTSTART}")"
    U_TIMEOUTSTOP="$(unit_time_seconds "${U_TIMEOUTSTOP}")"
    [ "${U_RESTARTSEC}" -ge 1 ] || U_RESTARTSEC=1
    [ "${U_TIMEOUTSTART}" -ge 1 ] || U_TIMEOUTSTART=5

    [ "${#U_EXECSTART[@]}" -gt 0 ]
}

# Parses by name, doing the lookup as well. Sets U_* and UNIT_FILE_PATH.
# Returns 1 not found, 2 masked, 3 nothing to execute.
unit_load() {
    local name file
    name="$(unit_full_name "$1")"
    file="$(unit_file "${name}")" || return 1
    if [ -L "${file}" ] && [ "$(readlink -f "${file}" 2>/dev/null)" = "/dev/null" ]; then
        U_NAME="${name}"; U_FILE="${file}"
        return 2
    fi
    unit_parse "${name}" "${file}" || return 3
    return 0
}

# --- conditions --------------------------------------------------------------

# Evaluates one Condition*/Assert* entry, given as "Name=value" with systemd's
# leading "!" negation on the value. Unknown condition names are treated as
# satisfied: this list is a subset on purpose, and failing a unit over a
# condition this cannot evaluate would be worse than running it.
unit_condition_met() {
    local name="${1%%=*}" value="${1#*=}" negate="" result=1
    case "${value}" in "!"*) negate=1; value="${value#!}" ;; esac
    value="${value#"${value%%[![:space:]]*}"}"

    case "${name}" in
        PathExists) [ -e "${value}" ] && result=0 ;;
        PathExistsGlob) compgen -G "${value}" >/dev/null 2>&1 && result=0 ;;
        PathIsDirectory) [ -d "${value}" ] && result=0 ;;
        PathIsSymbolicLink) [ -L "${value}" ] && result=0 ;;
        PathIsReadWrite) [ -w "${value}" ] && result=0 ;;
        DirectoryNotEmpty) [ -d "${value}" ] && [ -n "$(ls -A "${value}" 2>/dev/null)" ] && result=0 ;;
        FileNotEmpty) [ -s "${value}" ] && result=0 ;;
        FileIsExecutable) [ -x "${value}" ] && [ -f "${value}" ] && result=0 ;;
        User)
            case "${value}" in
                "@system") [ "$(id -u)" -lt 1000 ] && result=0 ;;
                *[!0-9]*) [ "${value}" = "$(id -un)" ] && result=0 ;;
                *) [ "${value}" = "$(id -u)" ] && result=0 ;;
            esac
            ;;
        Group)
            case "${value}" in
                *[!0-9]*) id -Gn | tr ' ' '\n' | grep -Fxq "${value}" && result=0 ;;
                *) id -G | tr ' ' '\n' | grep -Fxq "${value}" && result=0 ;;
            esac
            ;;
        # Everything here runs in a container, always. A unit that asks to run
        # only outside one - ConditionVirtualization=no - is telling us it does
        # not belong in this add-on, and that is worth honouring rather than
        # ignoring.
        Virtualization)
            case "${value}" in
                no | "false") result=1 ;;
                yes | "true" | container | docker | container-other | podman) result=0 ;;
                *) result=1 ;;
            esac
            ;;
        Host)
            [ "${value}" = "$(hostname 2>/dev/null)" ] && result=0
            ;;
        KernelCommandLine)
            grep -qw -- "${value}" /proc/cmdline 2>/dev/null && result=0
            ;;
        Environment)
            case "${value}" in
                *=*) [ "$(printenv "${value%%=*}" 2>/dev/null)" = "${value#*=}" ] && result=0 ;;
                *) printenv "${value}" >/dev/null 2>&1 && result=0 ;;
            esac
            ;;
        *) result=0 ;;
    esac

    [ -n "${negate}" ] && { [ "${result}" -eq 0 ] && return 1 || return 0; }
    return "${result}"
}

# All conditions of the loaded unit. Sets UNIT_CONDITION_FAILED to the one that
# said no, for the log line and for `systemctl status`.
unit_conditions_ok() {
    local entry
    UNIT_CONDITION_FAILED=""
    for entry in ${U_CONDITIONS[@]+"${U_CONDITIONS[@]}"}; do
        if ! unit_condition_met "${entry}"; then
            UNIT_CONDITION_FAILED="Condition${entry}"
            return 1
        fi
    done
    for entry in ${U_ASSERTS[@]+"${U_ASSERTS[@]}"}; do
        if ! unit_condition_met "${entry}"; then
            UNIT_CONDITION_FAILED="Assert${entry}"
            return 2
        fi
    done
    return 0
}

# --- environment -------------------------------------------------------------

# systemd's EnvironmentFile format is NAME=value per line, with # and ;
# comments, and optional quotes around the value. It is *not* a shell script,
# and reading it with `.` - which is what this used to do - runs whatever is in
# it and mis-parses values containing spaces or a lone quote.
unit_load_environment_file() {
    local file="$1" line name value
    while IFS= read -r line || [ -n "${line}" ]; do
        line="${line#"${line%%[![:space:]]*}"}"
        case "${line}" in "" | "#"* | ";"*) continue ;; esac
        case "${line}" in *=*) ;; *) continue ;; esac
        name="${line%%=*}"
        value="${line#*=}"
        name="${name%"${name##*[![:space:]]}"}"
        case "${name}" in "" | *[!A-Za-z0-9_]*) continue ;; esac
        value="$(unit_split_words "${value}" | head -n1)"
        export "${name}=${value}"
    done < "${file}"
    return 0
}

# Applies Environment= and EnvironmentFile= to the *current* shell. Called
# inside the subshell that is about to become the service, never in the
# supervisor itself.
unit_prepare_environment() {
    local assignment file optional

    # The service is not a login shell and inherits this process's environment,
    # which for a unit started from an SSH session would carry SSH_* and the
    # session's own variables. systemd starts services from a clean slate; the
    # closest thing that is still useful is dropping the session-specific ones.
    unset SSH_CLIENT SSH_CONNECTION SSH_TTY SSH_AUTH_SOCK 2>/dev/null || true

    for file in ${U_ENVIRONMENTFILE[@]+"${U_ENVIRONMENTFILE[@]}"}; do
        # A leading "-" means "skip if missing", which is common for the
        # /etc/sysconfig/<name> files a package may or may not ship.
        optional=""
        case "${file}" in -*) optional=1; file="${file#-}" ;; esac
        if [ -r "${file}" ]; then
            unit_load_environment_file "${file}"
        elif [ -z "${optional}" ]; then
            printf 'EnvironmentFile %s is missing\n' "${file}" >&2
        fi
    done

    # After the files, so that Environment= in the unit wins over them - which
    # is systemd's order too.
    for assignment in ${U_ENVIRONMENT[@]+"${U_ENVIRONMENT[@]}"}; do
        export "${assignment?}" 2>/dev/null || \
            printf 'Environment entry %s is not a valid assignment\n' "${assignment}" >&2
    done

    # WorkingDirectory=-/path means "carry on if it is not there", and a
    # missing directory is not worth refusing to start over in either case:
    # the service is about to say so itself, in its own words.
    if [ -n "${U_WORKDIR}" ] && ! cd "${U_WORKDIR#-}" 2>/dev/null; then
        printf 'WorkingDirectory %s is not usable; staying in %s\n' "${U_WORKDIR#-}" "${PWD}" >&2
    fi
    return 0
}

# --- directories -------------------------------------------------------------

# RuntimeDirectory= and its siblings. Without these a unit that expects its
# directory to be made for it fails in a way that looks like the program's
# fault: tailscaled cannot create /run/tailscale/tailscaled.sock and exits.
# One kind of directory: a base (/run, /var/lib, ...), the mode, and the names
# from the unit. Names are relative and may contain a subdirectory, as in
# systemd; anything absolute or with a .. in it is refused rather than obeyed.
unit_mkdir_set() {
    local base="$1" dirmode="$2" owner="$3"; shift 3
    local names name dir
    for names in "$@"; do
        for name in ${names}; do
            case "${name}" in "" | /* | *..*) continue ;; esac
            dir="${base}/${name}"
            mkdir -p "${dir}" 2>/dev/null || continue
            chmod "${dirmode}" "${dir}" 2>/dev/null || true
            if [ -n "${owner}" ]; then
                chown -R "${owner}" "${dir}" 2>/dev/null || true
            fi
        done
    done
    return 0
}

unit_make_directories() {
    local owner=""
    if [ -n "${U_USER}" ]; then
        owner="${U_USER}"
        [ -n "${U_GROUP}" ] && owner="${owner}:${U_GROUP}"
    fi

    if [ "${#U_RUNTIMEDIR[@]}" -gt 0 ]; then
        unit_mkdir_set "${UNIT_RUNTIME_ROOT}" "${U_RUNTIMEDIRMODE}" "${owner}" "${U_RUNTIMEDIR[@]}"
    fi
    if [ "${#U_STATEDIR[@]}" -gt 0 ]; then
        unit_mkdir_set "${UNIT_STATE_ROOT}" "${U_STATEDIRMODE}" "${owner}" "${U_STATEDIR[@]}"
    fi
    if [ "${#U_CACHEDIR[@]}" -gt 0 ]; then
        unit_mkdir_set "${UNIT_CACHE_ROOT}" "${U_CACHEDIRMODE}" "${owner}" "${U_CACHEDIR[@]}"
    fi
    if [ "${#U_LOGSDIR[@]}" -gt 0 ]; then
        unit_mkdir_set "${UNIT_LOG_DIR%/*}" "${U_LOGSDIRMODE}" "${owner}" "${U_LOGSDIR[@]}"
    fi
    if [ "${#U_CONFDIR[@]}" -gt 0 ]; then
        unit_mkdir_set "${UNIT_CONFIG_ROOT}" "${U_CONFDIRMODE}" "${owner}" "${U_CONFDIR[@]}"
    fi
    return 0
}

# RuntimeDirectory= is cleaned up when the unit stops, unless the unit says to
# keep it. The other kinds are persistent by definition and are left alone.
unit_clean_runtime_directories() {
    local names name
    case "${U_RUNTIMEDIRPRESERVE}" in yes | restart | 1 | true) return 0 ;; esac
    for names in ${U_RUNTIMEDIR[@]+"${U_RUNTIMEDIR[@]}"}; do
        for name in ${names}; do
            case "${name}" in "" | /* | *..*) continue ;; esac
            rm -rf "${UNIT_RUNTIME_ROOT:?}/${name}" 2>/dev/null || true
        done
    done
    return 0
}

# --- runtime state -----------------------------------------------------------

unit_state_dir() { printf '%s/%s\n' "${UNIT_RUN_DIR}" "$1"; }
unit_log_file() { printf '%s/%s.log\n' "${UNIT_LOG_DIR}" "$1"; }
unit_child_pidfile() { printf '%s/%s/child.pid\n' "${UNIT_RUN_DIR}" "$1"; }
unit_supervisor_pidfile() { printf '%s/%s/supervisor.pid\n' "${UNIT_RUN_DIR}" "$1"; }
unit_stop_flag() { printf '%s/%s/stop\n' "${UNIT_RUN_DIR}" "$1"; }
unit_result_file() { printf '%s/%s/result\n' "${UNIT_RUN_DIR}" "$1"; }

unit_pid_alive() {
    local pid
    pid="$(cat "$1" 2>/dev/null)" || return 1
    [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null
}

unit_is_supervised() { unit_pid_alive "$(unit_supervisor_pidfile "$1")"; }
unit_is_running() { unit_pid_alive "$(unit_child_pidfile "$1")"; }

# The last recorded outcome: one word, optionally followed by an exit status.
# Written by the supervisor so that a unit that is no longer running can still
# say whether it finished or failed - which is the difference between
# `inactive` and `failed`, and the whole point of `systemctl is-failed`.
unit_result() { cat "$(unit_result_file "$1")" 2>/dev/null; }

unit_set_result() {
    local name="$1"
    mkdir -p "$(unit_state_dir "${name}")" 2>/dev/null || true
    shift
    printf '%s\n' "$*" > "$(unit_result_file "${name}")" 2>/dev/null || true
}

# active | activating | deactivating | inactive | failed, as systemd words
# them. RemainAfterExit is why "exited" is a kind of active: a oneshot that set
# something up is still considered to be in effect after it returns.
unit_state_word() {
    local name="$1" result
    if unit_is_running "${name}"; then printf 'active'; return 0; fi
    result="$(unit_result "${name}")"
    case "${result}" in
        failed*) printf 'failed' ;;
        active-exited) printf 'active (exited)' ;;
        condition*) printf 'inactive (condition)' ;;
        *) if unit_is_supervised "${name}"; then printf 'activating'; else printf 'inactive'; fi ;;
    esac
}

unit_is_active() {
    unit_is_running "$1" && return 0
    case "$(unit_result "$1")" in active-exited) return 0 ;; esac
    return 1
}

unit_is_failed() {
    case "$(unit_result "$1")" in failed*) return 0 ;; esac
    return 1
}

unit_main_pid() { cat "$(unit_child_pidfile "$1")" 2>/dev/null; }

# Enabled means linked from some target's .wants/.requires directory, which is
# exactly what systemd's own `enable` writes.
unit_is_enabled() {
    local name="$1" dir
    for dir in "${UNIT_ETC_DIR}"/*.wants "${UNIT_ETC_DIR}"/*.requires; do
        [ -L "${dir}/${name}" ] && return 0
    done
    return 1
}

# Every unit linked into any target's wants/requires directory - what the boot
# sequence starts, and what `list-unit-files` calls enabled.
unit_enabled_units() {
    local dir link
    for dir in "${UNIT_ETC_DIR}"/*.wants "${UNIT_ETC_DIR}"/*.requires; do
        [ -d "${dir}" ] || continue
        for link in "${dir}"/*; do
            [ -e "${link}" ] || [ -L "${link}" ] || continue
            printf '%s\n' "${link##*/}"
        done
    done | sort -u
}

# --- running -----------------------------------------------------------------

# systemd's Exec* lines may start with prefixes: "-" ignore failure, ":" no
# environment expansion, "@" set argv[0], "+", "!" and "!!" adjust privileges.
# None of the privilege ones mean anything here (everything runs as root in a
# container that is already the sandbox), so they are stripped rather than
# honoured.
unit_strip_exec_prefix() {
    local cmd="$1"
    while :; do
        case "${cmd}" in
            [-@+!:]*) cmd="${cmd#?}" ;;
            *) break ;;
        esac
    done
    printf '%s\n' "${cmd}"
}

unit_exec_ignores_failure() {
    case "$1" in -*) return 0 ;; *) return 1 ;; esac
}

# StandardOutput=/StandardError=. The default - journal - is the pipe the
# supervisor already set up, so it needs no redirection here.
unit_apply_stdio() {
    local path

    # A redirection that cannot be opened is fatal to a non-interactive shell,
    # which would turn a mistyped path into a service that never starts and
    # says nothing about why. Each target is opened for a test first, and an
    # unusable one falls back to the log the supervisor already provides.
    case "${U_STDOUT}" in
        null) exec >/dev/null ;;
        file:* | append:*)
            path="${U_STDOUT#*:}"
            mkdir -p "${path%/*}" 2>/dev/null || true
            if : >> "${path}" 2>/dev/null; then
                case "${U_STDOUT}" in
                    file:*) exec > "${path}" ;;
                    *) exec >> "${path}" ;;
                esac
            else
                printf 'StandardOutput=%s is not writable; logging to the unit log instead\n' \
                    "${U_STDOUT}" >&2
            fi
            ;;
        # journal, inherit, tty and the socket/fd kinds all end up on the pipe
        # the supervisor set up, which is the closest thing here to a journal.
        *) : ;;
    esac

    case "${U_STDERR}" in
        null) exec 2>/dev/null ;;
        file:* | append:*)
            path="${U_STDERR#*:}"
            mkdir -p "${path%/*}" 2>/dev/null || true
            if : >> "${path}" 2>/dev/null; then
                case "${U_STDERR}" in
                    file:*) exec 2> "${path}" ;;
                    *) exec 2>> "${path}" ;;
                esac
            fi
            ;;
        *) : ;;
    esac
    return 0
}

# Limit* -> ulimit. Per-process and needs no cgroup, unlike the resource
# control directives, which is why these are applied and those are not.
unit_apply_limits() {
    local entry name value soft hard flag
    for entry in ${U_LIMITS[@]+"${U_LIMITS[@]}"}; do
        name="${entry%%=*}"
        value="${entry#*=}"
        case "${name}" in
            CPU) flag=t ;; FSIZE) flag=f ;; DATA) flag=d ;; STACK) flag=s ;;
            CORE) flag=c ;; RSS) flag=m ;; NOFILE) flag=n ;; AS) flag=v ;;
            NPROC) flag=u ;; MEMLOCK) flag=l ;; LOCKS) flag=x ;;
            SIGPENDING) flag=i ;; MSGQUEUE) flag=q ;; RTPRIO) flag=r ;;
            *) continue ;;
        esac
        soft="${value%%:*}"
        hard="${value#*:}"
        [ "${hard}" = "${value}" ] && hard="${soft}"
        [ "${soft}" = "infinity" ] && soft="unlimited"
        [ "${hard}" = "infinity" ] && hard="unlimited"
        ulimit -H -"${flag}" "${hard}" 2>/dev/null || true
        ulimit -S -"${flag}" "${soft}" 2>/dev/null || true
    done

    [ -n "${U_UMASK}" ] && { umask "${U_UMASK}" 2>/dev/null || true; }
    if [ -n "${U_OOM}" ]; then
        printf '%s\n' "${U_OOM}" > /proc/self/oom_score_adj 2>/dev/null || true
    fi
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
# metacharacters, which a unit file has no reason to contain. The one place it
# matters is ${VAR}, which systemd expands itself from the unit's environment
# and the shell expands from the same environment - so the result agrees.
unit_exec_in_place() {
    local cmd gid
    cmd="$(unit_strip_exec_prefix "$1")"
    unit_apply_limits

    if [ -n "${U_NICE}" ]; then
        cmd="nice -n ${U_NICE} ${cmd}"
    fi
    if [ -n "${U_ROOTDIR}" ] && [ -d "${U_ROOTDIR}" ]; then
        cmd="chroot ${U_ROOTDIR} ${cmd}"
    fi

    if [ -n "${U_USER}" ] && [ "${U_USER}" != "root" ] && [ "${U_USER}" != "0" ]; then
        gid="${U_GROUP}"
        [ -n "${gid}" ] || gid="$(id -gn "${U_USER}" 2>/dev/null)" || gid=""
        if [ -n "${gid}" ]; then
            if [ -n "${U_SUPGROUPS}" ]; then
                exec setpriv --reuid "${U_USER}" --regid "${gid}" \
                    --groups "${U_SUPGROUPS// /,}" bash -c "${cmd}"
            fi
            exec setpriv --reuid "${U_USER}" --regid "${gid}" --init-groups bash -c "${cmd}"
        fi
        exec setpriv --reuid "${U_USER}" --init-groups bash -c "${cmd}"
    fi
    exec bash -c "${cmd}"
}

# For the one-shot Exec* lines - Condition, Pre, Post, Stop, StopPost, Reload -
# which are waited for rather than supervised, so their PID does not matter.
unit_run_command() {
    (
        unit_prepare_environment
        unit_apply_stdio
        unit_exec_in_place "$1"
    )
}

# Runs a list of Exec* lines in order. Returns the status of the first one that
# failed without a "-" prefix, which is systemd's rule for the Pre lines.
unit_run_command_list() {
    local -n _cmds="$1"
    local log="$2" cmd status
    for cmd in ${_cmds[@]+"${_cmds[@]}"}; do
        status=0
        unit_run_command "${cmd}" >> "${log}" 2>&1 || status=$?
        if [ "${status}" -ne 0 ] && ! unit_exec_ignores_failure "${cmd}"; then
            return "${status}"
        fi
    done
    return 0
}

unit_rotate_log() {
    local file="$1" size
    size="$(stat -c '%s' "${file}" 2>/dev/null)" || return 0
    [ "${size}" -gt "${UNIT_LOG_MAX_BYTES}" ] || return 0
    mv -f "${file}" "${file}.1" 2>/dev/null || true
}

# --- restart policy ----------------------------------------------------------

# SuccessExitStatus= accepts numbers and signal names, and 0 is always success.
unit_exit_is_success() {
    local status="$1" entry token
    [ "${status}" = "0" ] && return 0
    for entry in ${U_SUCCESSEXIT[@]+"${U_SUCCESSEXIT[@]}"}; do
        for token in ${entry}; do
            [ "${token}" = "${status}" ] && return 0
            # A process killed by signal N reports 128+N here, which is how a
            # unit that lists SIGTERM as a success is meant to be read.
            if [ "${status}" -gt 128 ] 2>/dev/null; then
                [ "${token#SIG}" = "$(kill -l "$((status - 128))" 2>/dev/null)" ] && return 0
            fi
        done
    done
    return 1
}

unit_status_listed() {
    local status="$1"; shift
    local entry token
    for entry in "$@"; do
        for token in ${entry}; do
            [ "${token}" = "${status}" ] && return 0
        done
    done
    return 1
}

unit_should_restart() {
    local status="$1"

    unit_status_listed "${status}" ${U_RESTARTPREVENT[@]+"${U_RESTARTPREVENT[@]}"} && return 1
    unit_status_listed "${status}" ${U_RESTARTFORCE[@]+"${U_RESTARTFORCE[@]}"} && return 0

    case "${U_RESTART}" in
        always | unless-stopped) return 0 ;;
        on-success) unit_exit_is_success "${status}" ;;
        on-failure) ! unit_exit_is_success "${status}" ;;
        # "abnormal" is a signal or a timeout, not a non-zero exit; a process
        # killed by a signal exits with 128+N here.
        on-abnormal | on-abort) [ "${status}" -gt 128 ] 2>/dev/null ;;
        on-watchdog) return 1 ;;
        *) return 1 ;;
    esac
}

# --- supervising -------------------------------------------------------------

# Starts the main process in a process group of its own and returns once it has
# exited, with its status in UNIT_LAST_STATUS. Job control is used on purpose:
# it puts each background job in a process group of its own, so stopping the
# unit can signal the whole group - the service and whatever it spawned - the
# way systemd signals a cgroup. Without it the group is the supervisor's own,
# and signalling it would kill the supervisor along with the service.
unit_run_main() {
    local name="$1" cmd="$2" log="$3"
    local status

    # Type=forking is a different shape of problem and gets its own path.
    if [ "${U_TYPE}" = "forking" ]; then
        unit_run_forking "${name}" "${cmd}" "${log}"
        return 0
    fi

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
            unit_apply_stdio
            unit_exec_in_place "${cmd}"
        ) &
        printf '%s\n' "$!" > "$(unit_child_pidfile "${name}")"
        wait "$!"
    } 2>&1 | sed -u "s/^/[${U_SYSLOGID:-${name}}] /" | tee -a "${log}"
    # Read before anything else runs: PIPESTATUS is rewritten by every
    # pipeline, and a simple command is a pipeline of one - `set +m` first
    # would leave this reading the status of `set`, which is always 0.
    status="${PIPESTATUS[0]}"
    set +m

    UNIT_LAST_STATUS="${status}"
    return 0
}

# Type=forking: what ExecStart runs is expected to start the real daemon and
# then exit, so the unit is the process it left behind, named by PIDFile=.
#
# The output cannot go through the tagging pipeline the other types use. A
# pipeline ends when every process holding its write end has exited, and the
# forked daemon inherits that end - so waiting for the pipeline would mean
# waiting for the daemon, and the fork would never be noticed until the
# service was already over. The initial process's output goes straight to the
# unit's log file instead; the daemon's own output is its business, which is
# what its PIDFile-and-detach design says in the first place.
unit_run_forking() {
    local name="$1" cmd="$2" log="$3"
    local pidfile="${U_PIDFILE}" status=0 pid waited=0

    # A PID file left behind by an earlier start would be read below as the PID
    # of the process that is about to fork. systemd removes the file it is
    # about to wait for, and so does this.
    [ -n "${pidfile}" ] && rm -f "${pidfile}"

    unit_run_command "${cmd}" >> "${log}" 2>&1 || status=$?
    if [ "${status}" -ne 0 ]; then
        printf '[%s] the forking start command failed with status %s\n' "${name}" "${status}" \
            | tee -a "${log}"
        UNIT_LAST_STATUS="${status}"
        return 0
    fi

    if [ -z "${pidfile}" ]; then
        printf '[%s] Type=forking without PIDFile=: the daemon it left behind cannot be found,\n' \
            "${name}" | tee -a "${log}"
        printf '[%s] so there is nothing to supervise and nothing to stop.\n' \
            "${name}" | tee -a "${log}"
        UNIT_LAST_STATUS=0
        return 0
    fi

    while [ "${waited}" -lt "${U_TIMEOUTSTART}" ] && [ ! -s "${pidfile}" ]; do
        sleep 1
        waited=$((waited + 1))
    done

    pid="$(cat "${pidfile}" 2>/dev/null)"
    if [ -z "${pid}" ] || ! kill -0 "${pid}" 2>/dev/null; then
        printf '[%s] PIDFile %s never named a running process\n' "${name}" "${pidfile}" \
            | tee -a "${log}"
        UNIT_LAST_STATUS=1
        return 0
    fi

    printf '%s\n' "${pid}" > "$(unit_child_pidfile "${name}")"
    printf '[%s] forked; main pid %s from %s\n' "${name}" "${pid}" "${pidfile}" | tee -a "${log}"

    # Polling, because the daemon is not this shell's child and `wait` cannot
    # be used on a process that is not.
    while kill -0 "${pid}" 2>/dev/null; do
        [ -e "$(unit_stop_flag "${name}")" ] && break
        sleep 1
    done

    UNIT_LAST_STATUS=0
    return 0
}

# Runs one unit and keeps it running according to Restart=. Blocks; callers
# background it. Output is tagged and written both to the unit's log file and
# to this process's stdout, which is the add-on log when the entrypoint started
# it.
unit_supervise() {
    local name="$1"
    local state log stop_flag delay started ended status cmd condition_status

    # The entrypoint sources this library with `set -e`, and this function is
    # the one that runs other people's programs and expects them to fail: an
    # ExecStartPre that returns non-zero, a service that crashes, a condition
    # that is not met. Every one of those is handled below, and none of them
    # may take the shell down on the way. Supervision always happens in a
    # subshell (a background job at boot, the whole process for
    # `systemctl start`), so this is local to it.
    set +e

    state="$(unit_state_dir "${name}")"
    log="$(unit_log_file "${name}")"
    stop_flag="$(unit_stop_flag "${name}")"

    mkdir -p "${state}" "${UNIT_LOG_DIR}"
    rm -f "${stop_flag}" "$(unit_result_file "${name}")"
    printf '%s\n' "$$" > "$(unit_supervisor_pidfile "${name}")"

    condition_status=0
    unit_conditions_ok || condition_status=$?
    if [ "${condition_status}" -ne 0 ]; then
        # systemd's distinction: a Condition that is not met means "there was
        # nothing to do here", which is a success; a failed Assert is an error.
        if [ "${condition_status}" -eq 1 ]; then
            printf '[%s] %s was not met, so it was not started\n' "${name}" \
                "${UNIT_CONDITION_FAILED}" | tee -a "${log}"
            unit_set_result "${name}" "condition"
        else
            printf '[%s] %s failed\n' "${name}" "${UNIT_CONDITION_FAILED}" | tee -a "${log}"
            unit_set_result "${name}" "failed 1"
        fi
        rm -f "$(unit_supervisor_pidfile "${name}")"
        return 0
    fi

    unit_make_directories

    # ExecCondition= is a Condition that runs a program: a non-zero status
    # under 255 means "skip this unit", 255 or a signal means it failed.
    for cmd in ${U_EXECCONDITION[@]+"${U_EXECCONDITION[@]}"}; do
        status=0
        unit_run_command "${cmd}" >> "${log}" 2>&1 || status=$?
        if [ "${status}" -ne 0 ]; then
            if [ "${status}" -lt 255 ]; then
                printf '[%s] ExecCondition said no (status %s); not starting\n' \
                    "${name}" "${status}" | tee -a "${log}"
                unit_set_result "${name}" "condition"
            else
                printf '[%s] ExecCondition failed (status %s)\n' "${name}" "${status}" \
                    | tee -a "${log}"
                unit_set_result "${name}" "failed ${status}"
            fi
            rm -f "$(unit_supervisor_pidfile "${name}")"
            return 0
        fi
    done

    if ! unit_run_command_list U_EXECSTARTPRE "${log}"; then
        printf '[%s] ExecStartPre failed, not starting\n' "${name}" | tee -a "${log}"
        unit_set_result "${name}" "failed 1"
        rm -f "$(unit_supervisor_pidfile "${name}")"
        return 1
    fi

    delay="${U_RESTARTSEC}"
    while :; do
        [ -e "${stop_flag}" ] && break
        unit_rotate_log "${log}"
        started="$(date '+%s')"
        status=0

        if [ "${U_TYPE}" = "oneshot" ]; then
            # Only oneshot may carry several ExecStart lines, and they run in
            # order, each waited for.
            for cmd in "${U_EXECSTART[@]}"; do
                unit_run_command "${cmd}" 2>&1 | sed -u "s/^/[${U_SYSLOGID:-${name}}] /" | tee -a "${log}"
                status="${PIPESTATUS[0]}"
                if [ "${status}" -ne 0 ] && ! unit_exec_ignores_failure "${cmd}"; then break; fi
                status=0
            done
        else
            unit_run_main "${name}" "${U_EXECSTART[0]}" "${log}"
            status="${UNIT_LAST_STATUS}"
        fi

        rm -f "$(unit_child_pidfile "${name}")"

        # ExecStartPost belongs after the process is up, not after it is gone -
        # but nothing here can tell "up" from "still running", so for a
        # long-running unit it is run once the first start has happened, and
        # for oneshot after the command returns, which is where systemd runs it.
        if [ "${U_TYPE}" = "oneshot" ] && [ "${status}" -eq 0 ]; then
            unit_run_command_list U_EXECSTARTPOST "${log}" || true
        fi

        # ExecStopPost runs whenever the service stops, however it stopped.
        unit_run_command_list U_EXECSTOPPOST "${log}" || true

        if [ -e "${stop_flag}" ]; then
            unit_set_result "${name}" "stopped"
            break
        fi

        if unit_exit_is_success "${status}"; then
            case "${U_REMAINAFTEREXIT}" in
                yes | true | 1) unit_set_result "${name}" "active-exited" ;;
                *) unit_set_result "${name}" "exited" ;;
            esac
        else
            unit_set_result "${name}" "failed ${status}"
        fi

        # Type=oneshot is expected to exit; that is not a failure to react to
        # unless the unit asked for a restart policy that covers it.
        if [ "${U_TYPE}" = "oneshot" ] && ! unit_should_restart "${status}"; then
            if [ "${status}" -ne 0 ]; then
                printf '[%s] failed with status %s\n' "${name}" "${status}" | tee -a "${log}"
            fi
            break
        fi

        if ! unit_should_restart "${status}"; then
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

    unit_clean_runtime_directories
    rm -f "$(unit_supervisor_pidfile "${name}")" "${stop_flag}"
    return 0
}

# --- stopping ----------------------------------------------------------------

# KillMode decides what gets the signal: the whole process group (the default,
# and the closest thing here to systemd's cgroup), the main process only, or -
# for "mixed" - the main process first and the group only when it comes to
# SIGKILL. "none" signals nothing, which is as unwise here as it is under
# systemd, and is honoured all the same.
unit_signal() {
    local pid="$1" signal="$2" scope="$3"
    [ -n "${pid}" ] || return 0
    case "${scope}" in
        group) kill -"${signal}" -- "-${pid}" 2>/dev/null || kill -"${signal}" "${pid}" 2>/dev/null || true ;;
        process) kill -"${signal}" "${pid}" 2>/dev/null || true ;;
        none) : ;;
    esac
    return 0
}

# Stops a loaded unit: ExecStop, then the signals, then ExecStopPost by way of
# the supervisor noticing the process is gone. Returns 0 once nothing is left.
unit_stop() {
    local name="$1"
    local log pid waited=0 scope="group" final_scope="group"

    # Same reason as unit_supervise: everything in here is allowed to fail, and
    # a stop that aborts half way leaves a unit neither running nor tidied up.
    set +e

    log="$(unit_log_file "${name}")"

    case "${U_KILLMODE}" in
        process) scope="process"; final_scope="process" ;;
        mixed) scope="process"; final_scope="group" ;;
        none) scope="none"; final_scope="none" ;;
        *) scope="group"; final_scope="group" ;;
    esac

    # The flag before anything else: the supervisor checks it the moment the
    # process exits, so setting it afterwards would race with a restart.
    mkdir -p "$(unit_state_dir "${name}")"
    : > "$(unit_stop_flag "${name}")"

    unit_run_command_list U_EXECSTOP "${log}" || true

    pid="$(unit_main_pid "${name}")"
    if [ -n "${pid}" ]; then
        unit_signal "${pid}" "${U_KILLSIGNAL}" "${scope}"
        while [ "${waited}" -lt "${U_TIMEOUTSTOP}" ] && kill -0 "${pid}" 2>/dev/null; do
            sleep 1
            waited=$((waited + 1))
        done
        if kill -0 "${pid}" 2>/dev/null; then
            case "${U_SENDSIGKILL}" in
                no | false | 0)
                    printf '[%s] still running after %ss; SendSIGKILL=no, leaving it\n' \
                        "${name}" "${U_TIMEOUTSTOP}" | tee -a "${log}" >&2
                    ;;
                *)
                    printf '[%s] ignored SIG%s for %ss; killing it\n' \
                        "${name}" "${U_KILLSIGNAL}" "${U_TIMEOUTSTOP}" | tee -a "${log}" >&2
                    unit_signal "${pid}" "${U_FINALKILLSIGNAL}" "${final_scope}"
                    ;;
            esac
        fi
    fi

    # Give the supervisor a moment to run ExecStopPost and tidy up before
    # signalling it, so a unit's own cleanup is not cut short.
    waited=0
    while [ "${waited}" -lt 5 ] && unit_is_supervised "${name}"; do
        sleep 1
        waited=$((waited + 1))
    done
    pid="$(cat "$(unit_supervisor_pidfile "${name}")" 2>/dev/null)"
    if [ -n "${pid}" ]; then
        kill -TERM "${pid}" 2>/dev/null || true
    fi

    unit_set_result "${name}" "stopped"
    rm -f "$(unit_child_pidfile "${name}")" "$(unit_stop_flag "${name}")"
    return 0
}

# --- dependencies ------------------------------------------------------------

# Units that name this one in PartOf= or BindsTo=, which is how systemd knows
# what else to stop when this stops. Found by reading the unit files, since
# there is no dependency graph kept anywhere.
unit_reverse_deps() {
    local name="$1" dir file
    for dir in "${UNIT_PATHS[@]}"; do
        [ -d "${dir}" ] || continue
        for file in "${dir}"/*.service; do
            [ -e "${file}" ] || continue
            if sed -nE 's/^(PartOf|BindsTo)=//p' "${file}" 2>/dev/null |
                    tr ' ' '\n' | grep -Fxq "${name}"; then
                printf '%s\n' "${file##*/}"
            fi
        done
    done | sort -u
}

# Orders a list of units so that whatever is named in After= comes first.
# A plain insertion sort over the pairs, which is enough for the handful of
# units an add-on runs and cannot loop for ever on a dependency cycle: the
# order it produces then is just the input order.
unit_ordering_keys() {
    local name="$1" file key
    file="$(unit_file "${name}")" || return 0
    sed -nE "s/^${2}=//p" "${file}" 2>/dev/null | tr ' ' '\n' | while IFS= read -r key; do
        [ -n "${key}" ] && unit_full_name "${key}"
    done
    return 0
}

# True when `first` has to be started before `second`, by either unit saying so.
unit_precedes() {
    local first="$1" second="$2"
    unit_ordering_keys "${second}" After | grep -Fxq "${first}" && return 0
    unit_ordering_keys "${first}" Before | grep -Fxq "${second}" && return 0
    return 1
}

# Orders units so that whatever is named in After= comes first. A bounded
# bubble sort: enough for the handful of units an add-on runs, and on a
# dependency cycle it stops improving rather than looping, leaving the input
# order - which is what systemd does with a cycle too, minus the warning.
unit_order() {
    local ordered=("$@") pass=0 swapped=1 i tmp
    while [ "${swapped}" -eq 1 ] && [ "${pass}" -le "${#ordered[@]}" ]; do
        swapped=0
        for (( i = 0; i + 1 < ${#ordered[@]}; i++ )); do
            if unit_precedes "${ordered[i + 1]}" "${ordered[i]}"; then
                tmp="${ordered[i]}"
                ordered[i]="${ordered[i + 1]}"
                ordered[i + 1]="${tmp}"
                swapped=1
            fi
        done
        pass=$((pass + 1))
    done
    [ "${#ordered[@]}" -gt 0 ] && printf '%s\n' "${ordered[@]}"
    return 0
}

# The units a start of this one pulls in: Requires=, Requisite=, Wants=,
# BindsTo=. Targets are inert here - they execute nothing - so what is returned
# is the service units among them, and what those in turn require.
unit_dependencies() {
    local name="$1" depth="${2:-0}" dep file
    [ "${depth}" -gt 5 ] && return 0

    file="$(unit_file "${name}")" || return 0
    while IFS= read -r dep; do
        [ -n "${dep}" ] || continue
        dep="$(unit_full_name "${dep}")"
        case "${dep}" in *.service) ;; *) continue ;; esac
        unit_file "${dep}" >/dev/null 2>&1 || continue
        printf '%s\n' "${dep}"
        unit_dependencies "${dep}" "$((depth + 1))"
    done < <(sed -nE 's/^(Requires|Requisite|Wants|BindsTo)=//p' "${file}" 2>/dev/null |
                 tr ' ' '\n' | sed '/^$/d')
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

# Starts everything enabled, which is what `systemctl enable` linked into a
# target's .wants directory. That directory is on /etc, which this add-on keeps
# on its persistent layer, so what you enabled once stays enabled across
# restarts and updates - the point of enabling something.
#
# Order comes from After=, so a unit that says it needs another one started
# first gets that, which is as much of systemd's ordering as makes sense
# without targets to synchronise on.
unit_start_enabled() {
    local name file started=() enabled=()

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

    while IFS= read -r name; do
        [ -n "${name}" ] && enabled+=("${name}")
    done < <(unit_enabled_units)
    [ "${#enabled[@]}" -gt 0 ] || return 0

    while IFS= read -r name; do
        [ -n "${name}" ] || continue

        if ! file="$(unit_file "${name}")"; then
            warn "Enabled unit ${name} has no unit file any more; skipping it."
            warn "Was its package removed? 'systemctl disable ${name}' clears this."
            continue
        fi
        if unit_is_masked "${name}"; then
            warn "Enabled unit ${name} is masked; skipping it."
            continue
        fi
        if ! unit_parse "${name}" "${file}"; then
            # A target or a socket unit linked here is not a fault: it has
            # nothing to execute, and saying so once is more use than a warning
            # that looks like an error.
            case "${name}" in
                *.service) warn "Enabled unit ${name} has no ExecStart; skipping it." ;;
                *) log "Enabled unit ${name} has nothing to execute; skipping it." ;;
            esac
            continue
        fi

        unit_supervise "${name}" &
        started+=("${name}")
    done < <(unit_order ${enabled[@]+"${enabled[@]}"})

    if [ "${#started[@]}" -gt 0 ]; then
        log "Started enabled units: ${started[*]}"
        log "Manage them with systemctl; their logs are in ${UNIT_LOG_DIR} and journalctl reads them"
    fi
    return 0
}
