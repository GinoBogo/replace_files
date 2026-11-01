#!/usr/bin/env bash
# ==============================================================================
# replace_files.sh – Replace every same-named file under a directory tree with a
#                    fresh copy of a source file, or with the source symlink.
#
# Walks <search-dir> recursively and, for every file or symlink whose basename
# matches one of the given sources, replaces it. What lands in place depends on
# the source: a real file is copied, a symlink is recreated, so after a run the
# targets always carry the source's kind.
#
# Author: Gino Bogo
# Date: 2026-11-01
# Version: see SCRIPT_VERSION
# ==============================================================================

set -euo pipefail

# ==============================================================================
# GLOBAL CONFIGURATION
# ==============================================================================

SCRIPT_VERSION="1.0"

# Associative arrays (duplicate detection) need bash 4.
if ((BASH_VERSINFO[0] < 4)); then
    printf 'bash 4 or newer is required; this is %s.\n' "${BASH_VERSION}" >&2
    exit 2
fi

# ANSI colour codes
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

SEPARATOR="----------------------------------------------------------------------"

# Options
SEARCH_DIR="."
TEST_MODE=false
ABSOLUTE_LINK=false

# Counters. FILE_COUNT and LINK_COUNT count the targets' final kind, which is
# also the source's kind, so the summary reads as "N real files, M links now".
FILE_COUNT=0
LINK_COUNT=0
SKIP_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

# Temporary files (find's diagnostics) removed on exit, including on abort.
TMP_FILES=()
# shellcheck disable=SC2329  # only invoked indirectly, by the trap below
cleanup_tmp() {
    local f
    for f in ${TMP_FILES[@]+"${TMP_FILES[@]}"}; do
        [[ -n "$f" ]] && rm -f -- "$f"
    done
    TMP_FILES=()
}
trap cleanup_tmp EXIT

# ==============================================================================
# SYSTEM VALIDATION
# ==============================================================================

for cmd in find cp ln rm basename dirname readlink mktemp; do
    if ! command -v "$cmd" > /dev/null 2>&1; then
        printf '%bError:%b required command not found: %s\n' \
            "$RED" "$RESET" "$cmd" >&2
        exit 3
    fi
done

# ==============================================================================
# USER INTERFACE
# ==============================================================================

log_info()  { printf '%b[INFO]%b %s\n' "$GREEN" "$RESET" "$*"; }
log_note()  { printf '%b[NOTE]%b %s\n' "$CYAN" "$RESET" "$*"; }
log_warn()  { WARN_COUNT=$((WARN_COUNT + 1)); printf '%b[WARN]%b %s\n' "$YELLOW" "$RESET" "$*" >&2; }
log_err()   { FAIL_COUNT=$((FAIL_COUNT + 1)); printf '%b[FAIL]%b %s\n' "$RED" "$RESET" "$*" >&2; }
log_test()  { printf '%b[TEST]%b %s\n' "$YELLOW" "$RESET" "$*"; }
log_result(){ printf '%b[OK]%b %s\n' "$GREEN" "$RESET" "$*"; }

sep()      { printf '\n%b%s%b\n' "$CYAN" "$SEPARATOR" "$RESET"; }

print_banner() {
    printf '\n%b%bReplace Files Utility v%s%b - by Gino Bogo\n' "$BOLD" "$CYAN" "$SCRIPT_VERSION" "$RESET"
    sep
}

# Function: print_usage
# Description: Displays the help menu and usage examples.
# Arguments: $1 - exit code (optional, default 1)
print_usage() {
    local script_name
    if ((${1:-1} != 0)); then
        exec 1>&2
    fi
    script_name=$(basename "${BASH_SOURCE[0]:-$0}")
    print_banner
    echo -e "${CYAN}Description:${RESET}"
    echo -e "  Walks a directory tree and replaces every file or symlink whose name"
    echo -e "  matches a source file with that source. A real-file source leaves real"
    echo -e "  files behind; a symlink source leaves symlinks behind."
    echo
    echo -e "${CYAN}Usage:${RESET}"
    echo -e "  $script_name [options] <source-file>..."
    echo
    echo -e "${CYAN}Arguments:${RESET}"
    echo -e "  ${GREEN}<source-file>${RESET}   One or more real files or symlinks whose basenames"
    echo -e "                  are matched. Repeat it to replace several names in one run."
    echo -e "                  Matching is exact and by name only; glob characters in a"
    echo -e "                  name are literal."
    echo
    echo -e "${CYAN}Options:${RESET}"
    echo -e "  ${GREEN}-d, --dir DIR${RESET}         Search root (default: .)"
    echo -e "  ${GREEN}-t, --test${RESET}            Dry run – only display the changes that would be made"
    echo -e "                        (alias: --dry-run)"
    echo -e "  ${GREEN}-a, --absolute-link${RESET}   Recreate symlinks with the source link's absolute"
    echo -e "                        destination instead of its verbatim text"
    echo -e "  ${GREEN}-h, --help${RESET}            Show this help message and exit"
    echo -e "  ${GREEN}-V, --version${RESET}         Show version and exit"
    echo -e "  ${GREEN}--${RESET}                    End of options (for sources starting with '-')"
    echo
    echo -e "${CYAN}Replacement rules:${RESET}"
    echo -e "  ${GREEN}real file -> real file${RESET}   content replaced, destination mode/owner kept"
    echo -e "  ${GREEN}real file -> symlink${RESET}     link removed, a real file takes its place"
    echo -e "  ${GREEN}symlink   -> real file${RESET}   file removed, the link is recreated"
    echo -e "  ${GREEN}symlink   -> symlink${RESET}     link removed, the link is recreated"
    echo
    echo -e "${CYAN}Examples:${RESET}"
    echo -e "  Dry run over a project tree:"
    echo -e "    ${GREEN}$script_name -t -d ./project ./shared/.clang-format${RESET}"
    echo
    echo -e "  Refresh every .clang-format copy under the projects root:"
    echo -e "    ${GREEN}$script_name -d ~/Projects ~/.config/clang-format${RESET}"
    echo
    echo -e "  Turn same-named files into links to a shared file:"
    echo -e "    ${GREEN}$script_name -a -d ./project ./shared/config.json${RESET}"
    echo
    echo -e "  Two names in one pass:"
    echo -e "    ${GREEN}$script_name -d ./project ./shared/a.h ./shared/b.h${RESET}"
    echo
    echo -e "${CYAN}Notes:${RESET}"
    echo -e "  Symlinks are never followed during the scan, so a target inside a"
    echo -e "  symlinked directory is not visited. The source itself is skipped."
    echo -e "  Without -a a relative source link keeps its text, which may dangle in"
    echo -e "  another directory; -a writes the resolved destination instead."
    echo
    echo -e "  Exit codes: 0 success (warnings allowed), 1 a copy/link failed,"
    echo -e "  2 bad usage or an unusable source, 3 a required command is missing."
    echo
    exit "${1:-1}"
}

# ==============================================================================
# INPUT PROCESSING
# ==============================================================================

SOURCE_FILES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d | --dir)
            [[ $# -ge 2 ]] || { log_err "Option $1 requires a value."; print_usage 2; }
            SEARCH_DIR="$2"; shift 2 ;;
        --dir=*)
            SEARCH_DIR="${1#*=}"; shift ;;
        -t | --test | --dry-run)
            TEST_MODE=true; shift ;;
        -a | --absolute-link)
            ABSOLUTE_LINK=true; shift ;;
        -h | --help)
            print_usage 0 ;;
        -V | --version)
            echo "replace_files.sh v${SCRIPT_VERSION}"
            exit 0 ;;
        --)
            shift; SOURCE_FILES+=("$@"); break ;;
        -*)
            log_err "Unknown option: $1"; print_usage 2 ;;
        *)
            SOURCE_FILES+=("$1"); shift ;;
    esac
done

((${#SOURCE_FILES[@]} > 0)) || { log_err "Missing source file."; print_usage 2; }

# The banner comes after argument parsing so --version and --help stay terse.
print_banner

if [[ ! -d "$SEARCH_DIR" ]]; then
    log_err "'$SEARCH_DIR' is not a valid directory."
    exit 2
fi

# Physical path: find output is compared string-wise against a source's resolved
# path, so both sides must be spelled the same way.
SEARCH_ABS="$(cd "$SEARCH_DIR" && pwd -P)"

# ==============================================================================
# ENVIRONMENT INITIALIZATION
# ==============================================================================

# One entry per source, in parallel arrays (bash cannot hold a list per element):
#   SRC_ABS   resolved absolute path, for the "do not copy onto itself" check
#   SRC_NAME  basename to match, also the key for duplicate detection
#   SRC_MODE  FILE for a regular file, LINK for a symlink (even dangling)
#   SRC_LINK  link text to write in LINK mode; empty in FILE mode
SRC_ABS=()
SRC_NAME=()
SRC_MODE=()
SRC_LINK=()
declare -A SEEN_PATH=()
declare -A SEEN_NAME=()

for src in "${SOURCE_FILES[@]}"; do
    # -L first: -f follows a link, so the order decides which mode wins.
    if [[ -L "$src" ]]; then
        mode="LINK"
    elif [[ -f "$src" ]]; then
        mode="FILE"
    elif [[ -d "$src" ]]; then
        log_err "'$src' is a directory, not a file."
        exit 2
    elif [[ -e "$src" ]]; then
        log_err "'$src' is not a regular file or a symlink."
        exit 2
    else
        log_err "'$src' does not exist."
        exit 2
    fi

    if ! src_dir="$(cd -- "$(dirname -- "$src")" 2> /dev/null && pwd -P)"; then
        log_err "cannot resolve the directory of '$src'."
        exit 2
    fi
    abs="$src_dir/$(basename -- "$src")"
    name=$(basename -- "$src")

    # The same path twice is harmless and collapses to one replacement. Two
    # different files with the same name are not: matching is by name, so one
    # would silently win and nothing would say so, so refuse.
    if [[ -n "${SEEN_PATH[$abs]:-}" ]]; then
        log_warn "'$src' is the same path twice; replacing it once."
        continue
    fi
    if [[ -n "${SEEN_NAME[$name]:-}" ]]; then
        log_err "Two different files are both named '$name':"
        log_err "  ${SEEN_NAME[$name]}"
        log_err "  $abs"
        log_err "Matching is by name, so one would silently win. Run them separately,"
        log_err "or rename one of them."
        exit 2
    fi

    link_dest=""
    if [[ "$mode" == "LINK" ]]; then
        if ! link_dest="$(readlink -- "$src")"; then
            log_err "cannot read the link '$src'."
            exit 2
        fi
        if [[ ! -e "$src" ]]; then
            log_warn "'$src' is a dangling symlink; the copies will be dangling too."
        elif [[ -d "$src" ]]; then
            log_warn "'$src' points to a directory; targets will become directory links."
        fi
        if $ABSOLUTE_LINK; then
            # A chained link resolves fully here, and so does a dangling final
            # component, because GNU readlink -f only requires the parent to
            # exist. A loop or a missing parent directory fails, and then the
            # verbatim text is the only thing left to write.
            if resolved="$(readlink -f -- "$src" 2> /dev/null)" && [[ -n "$resolved" ]]; then
                link_dest="$resolved"
            else
                log_warn "cannot resolve '$src' to an absolute destination; writing its text verbatim."
            fi
        fi
    fi

    SRC_ABS+=("$abs")
    SRC_NAME+=("$name")
    SRC_MODE+=("$mode")
    SRC_LINK+=("$link_dest")
    SEEN_PATH["$abs"]=true
    SEEN_NAME["$name"]="$abs"
done

SRC_COUNT=${#SRC_ABS[@]}

log_note "Search root: $SEARCH_ABS"

if $TEST_MODE; then
    log_test "TEST MODE: no files will be modified"
fi

# ==============================================================================
# CORE LOGIC
# ==============================================================================

# Function: glob_escape
# Description: Escapes the glob metacharacters find(1) understands, so a source
#              literally named e.g. "x[1].conf" is matched as that name instead
#              of as a pattern that also hits "x1.conf".
# Arguments: $1 - name to escape
# Returns:   the escaped name on stdout
glob_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\*/\\*}"
    s="${s//\?/\\?}"
    s="${s//\[/\\[}"
    s="${s//\]/\\]}"
    printf '%s' "$s"
}

# Function: replace_match
# Description: Brings one target in line with its source: a real-file source is
#              copied in, a symlink source is recreated. The target is unlinked
#              first whenever it is a link, because cp(1) and ln(1) would
#              otherwise follow it and leave the link in place.
# Arguments: $1 - resolved source path, $2 - FILE or LINK, $3 - link text,
#            $4 - target path
replace_match() {
    local src="$1" mode="$2" link_dest="$3" target="$4"
    local kind label err

    # The source itself is never its own target.
    if [[ "$target" == "$src" ]]; then
        SKIP_COUNT=$((SKIP_COUNT + 1))
        return 0
    fi
    # In FILE mode the same inode reached under another spelling is the source
    # too. A symlink is excluded: replacing a link that points at the source is
    # exactly what this tool is for, and it never touches the source's bytes.
    if [[ "$mode" == "FILE" && ! -L "$target" && "$target" -ef "$src" ]]; then
        SKIP_COUNT=$((SKIP_COUNT + 1))
        return 0
    fi

    if [[ -L "$target" ]]; then kind="symlink"; else kind="file"; fi

    if [[ "$mode" == "FILE" ]]; then
        label="[$kind->file]"
        if $TEST_MODE; then
            log_test "would replace $label $target"
            FILE_COUNT=$((FILE_COUNT + 1))
            return 0
        fi
        if [[ -L "$target" ]] && ! rm -f -- "$target"; then
            log_err "failed to remove symlink: $target"
            return 0
        fi
        if err=$(cp -f -- "$src" "$target" 2>&1); then
            log_info "replaced $label $target"
            FILE_COUNT=$((FILE_COUNT + 1))
        else
            log_err "failed to copy onto $target ($err)"
        fi
        return 0
    fi

    label="[$kind->link]"
    if $TEST_MODE; then
        log_test "would replace $label $target -> $link_dest"
        LINK_COUNT=$((LINK_COUNT + 1))
        return 0
    fi
    if ! rm -f -- "$target"; then
        log_err "failed to remove: $target"
        return 0
    fi
    if err=$(ln -s -- "$link_dest" "$target" 2>&1); then
        log_info "replaced $label $target -> $link_dest"
        LINK_COUNT=$((LINK_COUNT + 1))
        [[ -e "$target" ]] || log_warn "created link is dangling: $target"
    else
        log_err "failed to create link at $target ($err)"
    fi
}

# ==============================================================================
# EXECUTION LOOP
# ==============================================================================

for idx in "${!SRC_ABS[@]}"; do
    src="${SRC_ABS[$idx]}"
    name="${SRC_NAME[$idx]}"
    mode="${SRC_MODE[$idx]}"
    link_dest="${SRC_LINK[$idx]}"
    pattern="$(glob_escape "$name")"

    log_info "Source[$((idx + 1))/$SRC_COUNT]: $src [$mode]"
    log_info "Searching '$SEARCH_ABS' for '$name' ..."
    sep

    # find never follows links, so the -type l branch reports the link itself
    # rather than whatever it points at, and links inside the tree are visited.
    # -print0 / read -d '' keeps names with spaces or newlines in one piece.
    find_err=$(mktemp) || { log_err "cannot create a temporary file."; exit 1; }
    TMP_FILES+=("$find_err")

    matches=0
    while IFS= read -r -d '' target; do
        matches=$((matches + 1))
        replace_match "$src" "$mode" "$link_dest" "$target"
    done < <(find "$SEARCH_ABS" \( -type f -o -type l \) -name "$pattern" -print0 2> "$find_err")

    # An unreadable subtree used to vanish without a word; report find's own
    # complaints so a short run is never mistaken for a complete one.
    if [[ -s "$find_err" ]]; then
        while IFS= read -r line; do
            log_err "${line#find: }"
        done < "$find_err"
    fi
    rm -f -- "$find_err"

    if ((matches == 0)); then
        log_warn "no match for '$name' under $SEARCH_ABS"
    fi

    sep
done

# ==============================================================================
# SUMMARY
# ==============================================================================

if $TEST_MODE; then
    log_test "TEST MODE: no files were modified"
fi

log_result "Replaced ${BOLD}${GREEN}${FILE_COUNT}${RESET}${CYAN} real file(s) and ${BOLD}${GREEN}${LINK_COUNT}${RESET}${CYAN} symlink(s); ${BOLD}${YELLOW}${SKIP_COUNT}${RESET}${CYAN} skipped.${RESET}"

if ((FAIL_COUNT > 0)); then
    log_err "completed with $FAIL_COUNT failure(s)"
    exit 1
fi

# Stated rather than inherited: a clean run that replaced nothing should not
# report whatever status the last command happened to leave behind.
exit 0
