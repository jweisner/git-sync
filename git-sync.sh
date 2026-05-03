#!/usr/bin/env bash

set -uo pipefail

RED=$'\033[0;31m'
YELLOW=$'\033[1;33m'
GREEN=$'\033[0;32m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'
BOLD=$'\033[1m'
ERASE=$'\r\033[K'

UP='↑'
DOWN='↓'
DASH='—'
ELLIPSIS='…'
ARROW='→'

OFFLINE=0
SKIP_CLEAN=1
DRY_RUN=0
GIT_TIMEOUT=10
SKIP_REPO=0
_bg_pid=""
_last_int_at=0
_ssh_sock_dir=$(mktemp -d "${TMPDIR:-/tmp}/git-sync-ssh.XXXXXX")
declare -A _failed_hosts
declare -A _probed_hosts
PROBE_TIMEOUT=5
HAS_NC=0
if command -v nc >/dev/null 2>&1; then
    HAS_NC=1
fi

usage() {
    cat <<EOF
Usage: ${0##*/} [OPTIONS] [DIRECTORY]

Scan DIRECTORY (default: current directory) for git repositories,
fetch updates, pull fast-forwardable branches, and push local commits.

Options:
  -h, --help       Show this help message and exit
  -o, --offline     Skip fetching from remotes
  -v, --verbose    Show repos that are up to date in the summary
  -d, --dry-run    Show what would be done without making changes
  -a, --ascii      Use ASCII-only symbols in output
  -t, --timeout N  Seconds before a stalled remote operation times out (default: 10)

Press Ctrl+C to skip the current repo, or twice quickly to exit.
EOF
    exit 0
}

while getopts ":hovdat:-:" opt; do
    case "$opt" in
        h) usage ;;
        o) OFFLINE=1 ;;
        v) SKIP_CLEAN=0 ;;
        d) DRY_RUN=1 ;;
        a) UP='^'; DOWN='v'; DASH='--'; ELLIPSIS='~'; ARROW='->' ;;
        t) GIT_TIMEOUT="$OPTARG" ;;
        -)
            case "$OPTARG" in
                help)     usage ;;
                offline)  OFFLINE=1 ;;
                verbose)  SKIP_CLEAN=0 ;;
                dry-run)  DRY_RUN=1 ;;
                ascii)    UP='^'; DOWN='v'; DASH='--'; ELLIPSIS='~'; ARROW='->' ;;
                timeout)  GIT_TIMEOUT="${!OPTIND}"; OPTIND=$(( OPTIND + 1 )) ;;
                timeout=*) GIT_TIMEOUT="${OPTARG#*=}" ;;
                *) printf "Unknown option: --%s\n" "$OPTARG" >&2; exit 1 ;;
            esac
            ;;
        :) printf "Option -%s requires an argument\n" "$OPTARG" >&2; exit 1 ;;
        ?) printf "Unknown option: -%s\n" "$OPTARG" >&2; exit 1 ;;
    esac
done
shift $(( OPTIND - 1 ))

ROOT="${1:-$PWD}"
ROOT="${ROOT%/}"

if [[ ! -d "$ROOT" ]]; then
    printf "Error: '%s' is not a directory\n" "$ROOT" >&2
    exit 1
fi

_handle_int() {
    if (( SECONDS - _last_int_at <= 1 )); then
        printf "\n" >&2
        exit 130
    fi
    _last_int_at=$SECONDS
    SKIP_REPO=1
    if [[ -n "$_bg_pid" ]] && kill -0 "$_bg_pid" 2>/dev/null; then
        kill "$_bg_pid" 2>/dev/null
    fi
    printf "\n  %sSkipping repo (Ctrl+C again to exit)%s\n" "$YELLOW" "$NC" >&2
}
trap _handle_int INT

_cleanup() {
    rm -rf "$_ssh_sock_dir"
}
trap _cleanup EXIT

_get_remote_host() {
    local url="$1"
    if [[ "$url" =~ ^[a-z+]+:// ]]; then
        url="${url#*://}"
        url="${url#*@}"
        url="${url%%[:/]*}"
    else
        url="${url#*@}"
        url="${url%%:*}"
    fi
    printf '%s' "$url"
}

_get_remote_port() {
    local url="$1"
    if [[ "$url" =~ ^[a-z+]+:// ]]; then
        local authority="${url#*://}"
        authority="${authority%%/*}"
        authority="${authority#*@}"
        if [[ "$authority" =~ :([0-9]+)$ ]]; then
            printf '%s' "${BASH_REMATCH[1]}"
            return
        fi
    fi
    case "$url" in
        https://*) printf '443' ;;
        http://*)  printf '80' ;;
        git://*)   printf '9418' ;;
        *)         printf '22' ;;
    esac
}

_record_failed_host() {
    local repo="$1" remote_name="$2"
    local url host
    url=$(git -C "$repo" remote get-url "$remote_name" 2>/dev/null) || return
    host=$(_get_remote_host "$url")
    if [[ -n "$host" && -z "${_failed_hosts[$host]+x}" ]]; then
        _failed_hosts["$host"]=1
        unset '_probed_hosts[$host]'
        printf "  %sAll remotes at %s will be skipped%s\n" "$YELLOW" "$host" "$NC"
    fi
}

_check_remote_host() {
    local repo="$1" remote_name="$2"
    local url host port
    url=$(git -C "$repo" remote get-url "$remote_name" 2>/dev/null) || return 0
    host=$(_get_remote_host "$url")
    [[ -z "$host" ]] && return 0

    [[ -n "${_failed_hosts[$host]+x}" ]] && return 1
    [[ -n "${_probed_hosts[$host]+x}" ]] && return 0

    if [[ $HAS_NC -eq 0 ]]; then
        _probed_hosts["$host"]=1
        return 0
    fi

    port=$(_get_remote_port "$url")
    run_with_spinner "Probing $host:$port..." nc -z -w "$PROBE_TIMEOUT" "$host" "$port"
    if [[ $? -eq 0 ]]; then
        _probed_hosts["$host"]=1
        return 0
    else
        _failed_hosts["$host"]=1
        return 1
    fi
}

_is_connection_error() {
    [[ "$1" =~ (Connection timed out|Connection refused|Could not resolve|Could not read from remote|unable to access|the remote end hung up|Connection reset|transfer closed) ]]
}

_git() {
    local alive_interval=$(( GIT_TIMEOUT > 15 ? GIT_TIMEOUT / 3 : 5 ))
    local ssh_base="${GIT_SSH_COMMAND:-ssh}"
    GIT_SSH_COMMAND="${ssh_base} -o ConnectTimeout=${GIT_TIMEOUT} -o ServerAliveInterval=${alive_interval} -o ServerAliveCountMax=3 -o ControlMaster=auto -o ControlPath=${_ssh_sock_dir}/%r@%h:%p -o ControlPersist=60" \
        git -c "http.lowSpeedLimit=1000" -c "http.lowSpeedTime=${GIT_TIMEOUT}" "$@"
}

# Run a command with an ASCII spinner on stderr. Captures stdout+stderr into
# global $out. Returns the command's exit code.
out=""
run_with_spinner() {
    local msg="$1"; shift
    local tmp rc
    tmp=$(mktemp)

    "$@" >"$tmp" 2>&1 &
    _bg_pid=$!

    if [[ -t 2 ]]; then
        local frames=('-' '\' '|' '/') i=0
        while kill -0 "$_bg_pid" 2>/dev/null; do
            printf "${ERASE}  %s %s" "${frames[$((i % 4))]}" "$msg" >&2
            (( i++ )) || true
            sleep 0.1
        done
        printf "${ERASE}" >&2
    fi

    wait "$_bg_pid" 2>/dev/null; rc=$?
    _bg_pid=""
    out=$(cat "$tmp")
    rm -f "$tmp"
    return $rc
}

# Summary: parallel arrays
sum_names=()
sum_statuses=()
sum_colors=()
sum_details=()

record() {  # name status color detail
    sum_names+=("$1")
    sum_statuses+=("$2")
    sum_colors+=("$3")
    sum_details+=("$4")
}

push_ok=()
push_fail=()
do_push_all() {
    local repo="$1" name="$2"
    push_ok=()
    push_fail=()
    for r in "${remotes[@]}"; do
        [[ $SKIP_REPO -eq 1 ]] && break
        if ! _check_remote_host "$repo" "$r"; then
            push_fail+=("$r")
            printf "  %sSkipping push to %s (host unreachable)%s\n" "$YELLOW" "$r" "$NC"
            continue
        fi
        run_with_spinner "Pushing $name ${ARROW} $r..." _git -C "$repo" push "$r"; rc=$?
        if [[ $SKIP_REPO -eq 1 ]]; then
            break
        elif [[ $rc -ne 0 ]]; then
            push_fail+=("$r")
            if _is_connection_error "$out"; then
                _record_failed_host "$repo" "$r"
                printf "  %sPush to %s failed (connection error)%s\n" "$RED" "$r" "$NC"
            else
                printf "  %sPush to %s failed:%s\n" "$RED" "$r" "$NC"
                printf "%s\n" "$out" | sed 's/^/    /'
            fi
        else
            push_ok+=("$r")
        fi
    done
    if [[ ${#push_ok[@]} -gt 0 ]]; then
        printf "  %sPushed%s %s %s\n" "$GREEN" "$NC" "$ARROW" "$(IFS=', '; echo "${push_ok[*]}")"
    fi
}

if [[ $HAS_NC -eq 0 && $OFFLINE -eq 0 ]]; then
    printf "%sWarning: nc (netcat) not found; host probing disabled%s\n" "$YELLOW" "$NC" >&2
fi

found=0

header_printed=0
print_header() {
    if [[ $header_printed -eq 0 ]]; then
        printf "\n%s%s==> %s%s" "$BOLD" "$CYAN" "$repo" "$NC"
        if [[ ${#remotes[@]} -gt 1 ]]; then
            printf "  %s(%s)%s" "$CYAN" "$(IFS=', '; echo "${remotes[*]}")" "$NC"
        fi
        printf "\n"
        header_printed=1
    fi
}

while IFS= read -r -d '' gitdir; do
    repo="${gitdir%/.git}"
    name="${repo#"$ROOT"/}"
    found=1
    header_printed=0
    SKIP_REPO=0
    mapfile -t remotes < <(git -C "$repo" remote 2>/dev/null)

    fetch_skip=()
    fetch_fail=()
    if [[ $OFFLINE -eq 0 ]]; then
        for r in "${remotes[@]}"; do
            [[ $SKIP_REPO -eq 1 ]] && break
            if ! _check_remote_host "$repo" "$r"; then
                fetch_skip+=("$r")
                continue
            fi
            run_with_spinner "Fetching $name ${ARROW} $r..." _git -C "$repo" fetch "$r"; rc=$?
            if [[ $SKIP_REPO -eq 1 ]]; then
                break
            elif [[ $rc -ne 0 ]] && _is_connection_error "$out"; then
                _record_failed_host "$repo" "$r"
                fetch_fail+=("$r")
                print_header
                printf "  %sFetch from %s failed (connection error)%s\n" "$RED" "$r" "$NC"
            fi
        done
        if [[ $SKIP_REPO -eq 1 ]]; then
            record "$name" "skipped" "$YELLOW" "interrupted"
            continue
        fi
        if [[ $(( ${#fetch_skip[@]} + ${#fetch_fail[@]} )) -gt 0 && $(( ${#fetch_skip[@]} + ${#fetch_fail[@]} )) -eq ${#remotes[@]} ]]; then
            print_header
            local_err=()
            [[ ${#fetch_skip[@]} -gt 0 ]] && local_err+=("skipped: $(IFS=', '; echo "${fetch_skip[*]}")")
            [[ ${#fetch_fail[@]} -gt 0 ]] && local_err+=("failed: $(IFS=', '; echo "${fetch_fail[*]}")")
            record "$name" "fetch failed" "$RED" "$(IFS='; '; echo "${local_err[*]}")"
            continue
        fi
    fi

    fetch_warn=""
    if [[ $(( ${#fetch_skip[@]} + ${#fetch_fail[@]} )) -gt 0 ]]; then
        parts=()
        [[ ${#fetch_skip[@]} -gt 0 ]] && parts+=("skipped: $(IFS=', '; echo "${fetch_skip[*]}")")
        [[ ${#fetch_fail[@]} -gt 0 ]] && parts+=("failed: $(IFS=', '; echo "${fetch_fail[*]}")")
        fetch_warn=" ($(IFS='; '; echo "${parts[*]}"))"
    fi

    branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "(detached)")
    upstream=$(git -C "$repo" rev-parse --abbrev-ref '@{u}' 2>/dev/null || echo "")
    dirty=$(git -C "$repo" status --porcelain 2>/dev/null)

    if [[ -z "$upstream" ]]; then
        if [[ -z "$dirty" ]]; then
            record "$name" "no remote" "$YELLOW" "$branch"
        else
            print_header
            printf "  %sDirty%s $DASH no remote tracking branch (branch: %s)\n" "$RED" "$NC" "$branch"
            git -C "$repo" status --short 2>/dev/null | sed 's/^/    /'
            record "$name" "dirty/no remote" "$RED" "$branch"
        fi
        continue
    fi

    ahead=$(git -C "$repo" rev-list "${upstream}..HEAD" --count 2>/dev/null || echo "0")
    behind=$(git -C "$repo" rev-list "HEAD..${upstream}" --count 2>/dev/null || echo "0")

    if [[ -n "$dirty" ]]; then
        print_header
        printf "  %sDIRTY%s $DASH branch: %s\n" "$RED" "$NC" "$branch"
        git -C "$repo" status --short 2>/dev/null | sed 's/^/    /'

        if [[ "$behind" -gt 0 && "$ahead" -gt 0 ]]; then
            printf "  %sConflict risk:%s %d behind, %d local commits $DASH manual intervention needed\n" \
                "$RED" "$NC" "$behind" "$ahead"
            record "$name" "dirty/conflict" "$RED" "${behind}${DOWN} ${ahead}${UP} uncommitted"
        elif [[ "$behind" -gt 0 ]]; then
            printf "  %sCan pull:%s %d new remote commit(s) $DASH stash or commit first\n" \
                "$YELLOW" "$NC" "$behind"
            record "$name" "dirty/can pull" "$RED" "${behind}${DOWN} available"
        elif [[ "$ahead" -gt 0 ]]; then
            printf "  %s%d unpushed commit(s)%s $DASH commit or stash first\n" \
                "$YELLOW" "$ahead" "$NC"
            record "$name" "dirty/unpushed" "$RED" "${ahead}${UP} to push"
        else
            record "$name" "dirty" "$RED" "uncommitted changes"
        fi

    else
        if [[ "$ahead" -gt 0 && "$behind" -gt 0 ]]; then
            print_header
            if [[ $DRY_RUN -eq 1 ]]; then
                printf "  %sDiverged:%s %d ahead, %d behind on %s $DASH would push to %s\n" \
                    "$YELLOW" "$NC" "$ahead" "$behind" "$branch" "$(IFS=', '; echo "${remotes[*]}")"
                detail="diverged ${ahead}${UP} ${behind}${DOWN}"
                [[ ${#remotes[@]} -gt 1 ]] && detail+=" (${#remotes[@]} remotes)"
                record "$name" "would push" "$YELLOW" "$detail"
            else
                printf "  %sDiverged:%s %d ahead, %d behind on %s $DASH pushing\n" \
                    "$YELLOW" "$NC" "$ahead" "$behind" "$branch"
                do_push_all "$repo" "$name"
                if [[ $SKIP_REPO -eq 1 ]]; then
                    record "$name" "skipped" "$YELLOW" "interrupted"
                elif [[ ${#push_fail[@]} -eq 0 ]]; then
                    detail="${ahead}${UP} (was diverged)"
                    [[ ${#remotes[@]} -gt 1 ]] && detail="${ahead}${UP} (${#remotes[@]} remotes, was diverged)"
                    if [[ -n "$fetch_warn" ]]; then
                        record "$name" "pushed" "$YELLOW" "${detail}${fetch_warn}"
                    else
                        record "$name" "pushed" "$GREEN" "$detail"
                    fi
                elif [[ ${#push_ok[@]} -gt 0 ]]; then
                    record "$name" "partial push" "$YELLOW" "failed: $(IFS=', '; echo "${push_fail[*]}")${fetch_warn}"
                else
                    printf "  %sRebase required%s\n" "$RED" "$NC"
                    record "$name" "push failed" "$RED" "diverged ${ahead}${UP} ${behind}${DOWN}${fetch_warn}"
                fi
            fi
        elif [[ "$ahead" -gt 0 ]]; then
            print_header
            if [[ $DRY_RUN -eq 1 ]]; then
                printf "  %sUnpushed:%s %d commit(s) on %s $DASH would push to %s\n" \
                    "$YELLOW" "$NC" "$ahead" "$branch" "$(IFS=', '; echo "${remotes[*]}")"
                detail="${ahead}${UP}"
                [[ ${#remotes[@]} -gt 1 ]] && detail+=" (${#remotes[@]} remotes)"
                record "$name" "would push" "$YELLOW" "$detail"
            else
                printf "  %sUnpushed:%s %d commit(s) on %s $DASH pushing\n" \
                    "$YELLOW" "$NC" "$ahead" "$branch"
                do_push_all "$repo" "$name"
                if [[ $SKIP_REPO -eq 1 ]]; then
                    record "$name" "skipped" "$YELLOW" "interrupted"
                elif [[ ${#push_fail[@]} -eq 0 ]]; then
                    detail="${ahead}${UP}"
                    [[ ${#remotes[@]} -gt 1 ]] && detail+=" (${#remotes[@]} remotes)"
                    if [[ -n "$fetch_warn" ]]; then
                        record "$name" "pushed" "$YELLOW" "${detail}${fetch_warn}"
                    else
                        record "$name" "pushed" "$GREEN" "$detail"
                    fi
                elif [[ ${#push_ok[@]} -gt 0 ]]; then
                    record "$name" "partial push" "$YELLOW" "failed: $(IFS=', '; echo "${push_fail[*]}")${fetch_warn}"
                else
                    record "$name" "push failed" "$RED" "${ahead}${UP}${fetch_warn}"
                fi
            fi
        elif [[ "$behind" -gt 0 ]]; then
            print_header
            if [[ $DRY_RUN -eq 1 ]]; then
                printf "  %sClean%s $DASH %d commit(s) to pull on %s $DASH would pull\n" \
                    "$GREEN" "$NC" "$behind" "$branch"
                record "$name" "would pull" "$YELLOW" "${behind}${DOWN}"
            else
                printf "  %sClean%s $DASH %d commit(s) to pull on %s $DASH pulling\n" \
                    "$GREEN" "$NC" "$behind" "$branch"
                run_with_spinner "Pulling $name..." _git -C "$repo" pull --ff-only; rc=$?
                if [[ $SKIP_REPO -eq 1 ]]; then
                    record "$name" "skipped" "$YELLOW" "interrupted"
                elif [[ $rc -ne 0 ]] && _is_connection_error "$out"; then
                    _record_failed_host "$repo" "${upstream%%/*}"
                    printf "  %sPull failed (connection error)%s\n" "$RED" "$NC"
                    record "$name" "pull failed" "$RED" "connection error"
                elif [[ $rc -eq 0 ]]; then
                    printf "  %sPulled%s\n" "$GREEN" "$NC"
                    if [[ -n "$fetch_warn" ]]; then
                        record "$name" "pulled" "$YELLOW" "${behind}${DOWN}${fetch_warn}"
                    else
                        record "$name" "pulled" "$GREEN" "${behind}${DOWN}"
                    fi
                else
                    printf "%s\n" "$out" | sed 's/^/    /'
                    printf "  %sPull failed%s\n" "$RED" "$NC"
                    record "$name" "pull failed" "$RED" "${behind}${DOWN}"
                fi
            fi
        else
            if [[ -n "$fetch_warn" ]]; then
                record "$name" "up to date" "$YELLOW" "${branch}${fetch_warn}"
            else
                record "$name" "up to date" "$GREEN" "$branch"
            fi
        fi
    fi

done < <(find "$ROOT" -name ".git" -type d -prune -print0 2>/dev/null | sort -z)

if [[ "$found" -eq 0 ]]; then
    printf "No git repositories found in '%s'\n" "$ROOT"
    exit 0
fi

# Summary table

term_width=${COLUMNS:-$(tput cols 2>/dev/null)}
term_width=${term_width:-80}

col_name=4      # min width "Repo"
col_status=6    # min width "Status"
col_detail=7    # min width "Details"

for i in "${!sum_names[@]}"; do
    [[ ${#sum_names[$i]}    -gt $col_name   ]] && col_name=${#sum_names[$i]}
    [[ ${#sum_statuses[$i]} -gt $col_status ]] && col_status=${#sum_statuses[$i]}
    [[ ${#sum_details[$i]}  -gt $col_detail ]] && col_detail=${#sum_details[$i]}
done

col_name=$(( col_name + 2 ))
col_status=$(( col_status + 2 ))

# Cap the details column so the table fits within the terminal width
detail_avail=$(( term_width - col_name - col_status - 4 ))
[[ $detail_avail -lt 10 ]] && detail_avail=10
[[ $col_detail -gt $detail_avail ]] && col_detail=$detail_avail

total=$(( col_name + col_status + 4 + col_detail ))
sep=$(printf '%*s' "$total" '' | tr ' ' '-')

printf "\n%s%s SUMMARY%s\n" "$BOLD" "$CYAN" "$NC"
printf "%s%s%s\n" "$CYAN" "$sep" "$NC"
printf "%s%-*s  %-*s  Details%s\n" "$BOLD" "$col_name" "Repo" "$col_status" "Status" "$NC"
printf "%s%s%s\n" "$CYAN" "$sep" "$NC"

printed=0
for i in "${!sum_names[@]}"; do
    [[ $SKIP_CLEAN -eq 1 && "${sum_statuses[$i]}" == "up to date" && "${sum_colors[$i]}" == "$GREEN" ]] && continue
    name_col=$(printf "%-*s" "$col_name"   "${sum_names[$i]}")
    stat_col=$(printf "%-*s" "$col_status" "${sum_statuses[$i]}")
    detail="${sum_details[$i]}"
    [[ ${#detail} -gt $col_detail ]] && detail="${detail:0:$(( col_detail - 1 ))}${ELLIPSIS}"
    [[ "$detail" != "main" && "$detail" != "master" ]] && detail="${BOLD}${detail}${NC}"
    printf "%s  %s%s%s  %s\n" \
        "$name_col" \
        "${sum_colors[$i]}" "$stat_col" "$NC" \
        "$detail"
    (( printed++ )) || true
done
[[ $SKIP_CLEAN -eq 1 && $printed -eq 0 ]] && printf "  %sAll repos up to date%s\n" "$GREEN" "$NC"

printf "%s%s%s\n" "$CYAN" "$sep" "$NC"
