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

SKIP_FETCH=0
SKIP_CLEAN=1
DRY_RUN=0

while getopts ":nvda-:" opt; do
    case "$opt" in
        n) SKIP_FETCH=1 ;;
        v) SKIP_CLEAN=0 ;;
        d) DRY_RUN=1 ;;
        a) UP='^'; DOWN='v'; DASH='--'; ELLIPSIS='~'; ARROW='->' ;;
        -)
            case "$OPTARG" in
                no-fetch) SKIP_FETCH=1 ;;
                verbose)  SKIP_CLEAN=0 ;;
                dry-run)  DRY_RUN=1 ;;
                ascii)    UP='^'; DOWN='v'; DASH='--'; ELLIPSIS='~'; ARROW='->' ;;
                *) printf "Unknown option: --%s\n" "$OPTARG" >&2; exit 1 ;;
            esac
            ;;
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

# Run a command with an ASCII spinner on stderr. Captures stdout+stderr into
# global $out. Returns the command's exit code.
out=""
run_with_spinner() {
    local msg="$1"; shift
    local tmp rc
    tmp=$(mktemp)

    "$@" >"$tmp" 2>&1 &
    local cmd_pid=$!

    if [[ -t 2 ]]; then
        local frames=('-' '\' '|' '/') i=0
        while kill -0 "$cmd_pid" 2>/dev/null; do
            printf "${ERASE}  %s %s" "${frames[$((i % 4))]}" "$msg" >&2
            (( i++ )) || true
            sleep 0.1
        done
        printf "${ERASE}" >&2
    fi

    wait "$cmd_pid"; rc=$?
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
        run_with_spinner "Pushing $name ${ARROW} $r..." git -C "$repo" push "$r"
        if [[ $? -eq 0 ]]; then
            push_ok+=("$r")
        else
            push_fail+=("$r")
            printf "  %sPush to %s failed:%s\n" "$RED" "$r" "$NC"
            printf "%s\n" "$out" | sed 's/^/    /'
        fi
    done
    if [[ ${#push_ok[@]} -gt 0 ]]; then
        printf "  %sPushed%s %s %s\n" "$GREEN" "$NC" "$ARROW" "$(IFS=', '; echo "${push_ok[*]}")"
    fi
}

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

    if [[ $SKIP_FETCH -eq 0 ]]; then
        run_with_spinner "Fetching $name..." git -C "$repo" fetch --all || true
    fi

    branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "(detached)")
    upstream=$(git -C "$repo" rev-parse --abbrev-ref '@{u}' 2>/dev/null || echo "")
    dirty=$(git -C "$repo" status --porcelain 2>/dev/null)
    mapfile -t remotes < <(git -C "$repo" remote 2>/dev/null)

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
                if [[ ${#push_fail[@]} -eq 0 ]]; then
                    detail="${ahead}${UP} (was diverged)"
                    [[ ${#remotes[@]} -gt 1 ]] && detail="${ahead}${UP} (${#remotes[@]} remotes, was diverged)"
                    record "$name" "pushed" "$GREEN" "$detail"
                elif [[ ${#push_ok[@]} -gt 0 ]]; then
                    record "$name" "partial push" "$YELLOW" "failed: $(IFS=', '; echo "${push_fail[*]}")"
                else
                    printf "  %sRebase required%s\n" "$RED" "$NC"
                    record "$name" "push failed" "$RED" "diverged ${ahead}${UP} ${behind}${DOWN}"
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
                if [[ ${#push_fail[@]} -eq 0 ]]; then
                    detail="${ahead}${UP}"
                    [[ ${#remotes[@]} -gt 1 ]] && detail+=" (${#remotes[@]} remotes)"
                    record "$name" "pushed" "$GREEN" "$detail"
                elif [[ ${#push_ok[@]} -gt 0 ]]; then
                    record "$name" "partial push" "$YELLOW" "failed: $(IFS=', '; echo "${push_fail[*]}")"
                else
                    record "$name" "push failed" "$RED" "${ahead}${UP}"
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
                run_with_spinner "Pulling $name..." git -C "$repo" pull --ff-only; rc=$?
                if [[ $rc -eq 0 ]]; then
                    printf "  %sPulled%s\n" "$GREEN" "$NC"
                    record "$name" "pulled" "$GREEN" "${behind}${DOWN}"
                else
                    printf "%s\n" "$out" | sed 's/^/    /'
                    printf "  %sPull failed%s\n" "$RED" "$NC"
                    record "$name" "pull failed" "$RED" "${behind}${DOWN}"
                fi
            fi
        else
            record "$name" "up to date" "$GREEN" "$branch"
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
    [[ $SKIP_CLEAN -eq 1 && "${sum_statuses[$i]}" == "up to date" ]] && continue
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
