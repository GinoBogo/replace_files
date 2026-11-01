#!/usr/bin/env bash
# ==============================================================================
# test_replace_files.sh – Regression tests for Shell/replace_files.sh.
#
# Run from anywhere:  Shell/tests/test_replace_files.sh [-q] [-v] [-h]
#
#   -q   only the failures and the summary
#   -v   show each check as it runs
#   -h   this help
#
# Every check runs against fixture trees created under a temporary directory, so
# the repository is only ever read. Nothing here writes into it.
#
# Exit status: 0 when every check passes, 1 otherwise.
#
# Author: Gino Bogo
# Date: 2026-11
# Version: 1.0
# ==============================================================================

set -uo pipefail

# --- locate the script under test from here, following symlinks ---------------

SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE" ]]; do
    SOURCE_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ "$SOURCE" == /* ]] || SOURCE="$SOURCE_DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
SUT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
SUT="$SUT_DIR/replace_files.sh"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

QUIET=false
VERBOSE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -q) QUIET=true ;;
        -v) VERBOSE=true ;;
        -h | --help)
            sed -n '3,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            printf 'unknown option: %s (try --help)\n' "$1" >&2
            exit 2
            ;;
    esac
    shift
done

WORKDIR="$(mktemp -d)"
# shellcheck disable=SC2329  # only invoked indirectly, by the EXIT trap below
cleanup() { rm -rf -- "$WORKDIR"; }
trap cleanup EXIT

FX="$WORKDIR/fx"

# Snapshot of the script's own directory, to prove the suite never writes there.
DIR_SNAPSHOT="$(cd "$SUT_DIR" && find . \( -type f -o -type l \) | sort)"

# ==============================================================================
# ASSERTIONS
# ==============================================================================

PASSED=0
FAILED=0
OUT=""
WHY=""

note() { $QUIET || printf '%s\n' "$*"; }

# Runs the command, keeps its output in OUT with the SUT's ANSI colours stripped
# (its summary colours the numbers mid-line, so a plain substring would never
# match), and returns the command's own status -- not sed's.
capture() {
    $VERBOSE && note "    \$ ${*:-}"
    local rc=0
    OUT="$("$@" 2>&1)" || rc=$?
    OUT="$(printf '%s\n' "$OUT" | sed -e 's/\x1b\[[0-9;]*m//g')"
    return "$rc"
}

ran_ok() {
    local name="$1"
    shift
    local rc=0
    capture "$@" || rc=$?
    if ((rc == 0)); then
        PASSED=$((PASSED + 1))
        $QUIET || printf '  %sPASS%s %s\n' "$GREEN" "$RESET" "$name"
    else
        FAILED=$((FAILED + 1))
        printf '  %sFAIL%s %s\n' "$RED" "$RESET" "$name"
        printf '        exit %d: %s\n' "$rc" "${OUT:-(no output)}"
    fi
}

ran_no() {
    local name="$1"
    shift
    local rc=0
    capture "$@" || rc=$?
    if ((rc != 0)); then
        PASSED=$((PASSED + 1))
        $QUIET || printf '  %sPASS%s %s\n' "$GREEN" "$RESET" "$name"
    else
        FAILED=$((FAILED + 1))
        printf '  %sFAIL%s %s\n' "$RED" "$RESET" "$name"
        printf '        it succeeded: %s\n' "${OUT:-(no output)}"
    fi
}

says() {
    if [[ "$OUT" == *"$2"* ]]; then
        PASSED=$((PASSED + 1))
        $QUIET || printf '  %sPASS%s %s\n' "$GREEN" "$RESET" "$1"
    else
        FAILED=$((FAILED + 1))
        printf '  %sFAIL%s %s\n' "$RED" "$RESET" "$1"
        printf '        wanted %q in: %s\n' "$2" "${OUT:-(no output)}"
    fi
}

says_not() {
    if [[ "$OUT" != *"$2"* ]]; then
        PASSED=$((PASSED + 1))
        $QUIET || printf '  %sPASS%s %s\n' "$GREEN" "$RESET" "$1"
    else
        FAILED=$((FAILED + 1))
        printf '  %sFAIL%s %s\n' "$RED" "$RESET" "$1"
        printf '        did not want %q in: %s\n' "$2" "$OUT"
    fi
}

cond() {
    local name="$1"
    shift
    if "$@"; then
        PASSED=$((PASSED + 1))
        $QUIET || printf '  %sPASS%s %s\n' "$GREEN" "$RESET" "$name"
    else
        FAILED=$((FAILED + 1))
        printf '  %sFAIL%s %s\n' "$RED" "$RESET" "$name"
        [[ -n "$WHY" ]] && printf '        %s\n' "$WHY"
    fi
}

section() {
    note ""
    $QUIET || printf '%b%s%b\n' "$BOLD" "$1" "$RESET"
}

# ==============================================================================
# FIXTURE HELPERS
# ==============================================================================

# Predicates for cond(), which runs them through "$@" rather than by name.
# shellcheck disable=SC2329
is_real_file() { [[ -f "$1" && ! -L "$1" ]]; }
# shellcheck disable=SC2329
is_link_to() { [[ -L "$1" && "$(readlink -- "$1")" == "$2" ]]; }
# shellcheck disable=SC2329
is_dangling_link() { [[ -L "$1" && ! -e "$1" ]]; }
# shellcheck disable=SC2329
has_content() { [[ "$(cat -- "$1" 2> /dev/null)" == "$2" ]]; }
mode_of() { stat -c '%a' "$1"; }

# mkfix <dir>
# Builds the standard fixture. Targets are grouped by kind so a section can scan
# exactly the kind it is about:
#   tree/files/     real files named src.conf
#   tree/links/     a link named src.conf that points at the source
#   tree/dangling/  a dangling link named src.conf
#   tree/other/     a file with another name
#   tree/glob/      src[1].conf next to src1.conf
mkfix() {
    local d="$1"
    rm -rf -- "$d"
    mkdir -p "$d/tree/files/a" "$d/tree/files/b" "$d/tree/links" \
        "$d/tree/dangling" "$d/tree/other" "$d/tree/glob"

    printf 'FRESH\n' > "$d/src.conf"
    printf 'payload\n' > "$d/target.txt"

    printf 'old-a\n' > "$d/tree/files/a/src.conf"
    printf 'old-b\n' > "$d/tree/files/b/src.conf"
    ln -s ../../../src.conf "$d/tree/links/src.conf"
    ln -s ../nowhere "$d/tree/dangling/src.conf"
    printf 'keep\n' > "$d/tree/other/other.conf"
    printf 'old-g1\n' > "$d/tree/glob/src[1].conf"
    printf 'old-g2\n' > "$d/tree/glob/src1.conf"

    # Sources of the symlink kind: relative, chained and dangling.
    ln -s target.txt "$d/link.conf"
    ln -s target.txt "$d/mid.conf"
    ln -s mid.conf "$d/chain.conf"
    ln -s nowhere.conf "$d/dangle.conf"
}

# ==============================================================================

[ -f "$SUT" ] || {
    printf 'cannot find %s\n' "$SUT" >&2
    exit 2
}

note ""
$QUIET || printf '%b%btest_replace_files.sh%b\n' "$BOLD" "$CYAN" "$RESET"
$QUIET || printf '%b%s%b\n' "$CYAN" \
    "----------------------------------------------------------------------" "$RESET"

# ------------------------------------------------------------------------------
section "CLI surface"

ran_ok "script is syntactically valid" bash -n "$SUT"

ran_ok "-h prints help and exits 0" bash "$SUT" -h
says "-h shows Description" "Description:"
says "-h shows Usage" "Usage:"
says "-h shows Arguments" "Arguments:"
says "-h shows Options" "Options:"
says "-h shows Examples" "Examples:"

capture bash -c "bash '$SUT' --bogus 2>/dev/null"
says_not "unknown option keeps help off stdout" "Description"
capture bash -c "bash '$SUT' --bogus 2>&1 >/dev/null"
says "unknown option sends help to stderr" "Description"
says "unknown option prints the error" "Unknown option"

ran_ok "-V prints version and exits 0" bash "$SUT" -V
says "-V names the tool" "replace_files.sh v"
capture bash "$SUT" -V
says_not "-V keeps the banner off" "Replace Files Utility"

ran_no "no source is refused" bash "$SUT"
says "no-source error names the problem" "Missing source file"

ran_no "-d without a value is refused" bash "$SUT" -d
says "-d error mentions the option" "requires a value"

mkfix "$FX/cli"
CLI="$FX/cli"

ran_no "-d on a file is refused" bash "$SUT" -d "$CLI/src.conf" "$CLI/src.conf"
says "-d-on-file error says so" "not a valid directory"

ran_no "a missing search dir is refused" bash "$SUT" -d "$WORKDIR/nope" "$CLI/src.conf"
says "missing-dir error names the path" "not a valid directory"

ran_no "a missing source is refused" bash "$SUT" -d "$CLI/tree" "$CLI/missing.conf"
says "missing-source error says so" "does not exist"

ran_no "a directory source is refused" bash "$SUT" -d "$CLI/tree" "$CLI/tree/files/a"
says "directory-source error says so" "is a directory"

if mkfifo "$CLI/pipe.conf" 2> /dev/null; then
    ran_no "a fifo source is refused" bash "$SUT" -d "$CLI/tree" "$CLI/pipe.conf"
    says "fifo-source error says so" "not a regular file or a symlink"
fi

mkdir -p "$CLI/s1" "$CLI/s2"
printf 'x\n' > "$CLI/s1/dup.conf"
printf 'y\n' > "$CLI/s2/dup.conf"
ran_no "duplicate basenames are refused" bash "$SUT" -d "$CLI/tree" \
    "$CLI/s1/dup.conf" "$CLI/s2/dup.conf"
says "duplicate error names both" "both named 'dup.conf'"

ran_ok "the same path twice is accepted" bash "$SUT" -t -d "$CLI/tree" \
    "$CLI/src.conf" "$CLI/src.conf"
says "duplicate path warns" "same path twice"

# ------------------------------------------------------------------------------
section "banner prints once on normal run"

mkfix "$FX/banner"
capture bash "$SUT" -t -d "$FX/banner/tree/files" "$FX/banner/src.conf"
count=$(printf '%s\n' "$OUT" | grep -c 'Replace Files Utility' || true)
cond "the banner appears exactly once" test "$count" -eq 1

capture bash "$SUT" -h
count=$(printf '%s\n' "$OUT" | grep -c 'Replace Files Utility' || true)
cond "-h prints the banner exactly once" test "$count" -eq 1

# ------------------------------------------------------------------------------
section "file mode: real file targets"

mkfix "$FX/file"
F="$FX/file"
chmod 600 "$F/tree/files/b/src.conf"
source_sum="$(cksum < "$F/src.conf")"

ran_ok "replaces nested copies" bash "$SUT" -d "$F/tree/files" "$F/src.conf"
says "summary counts two real files" "2 real file(s) and 0 symlink(s)"
says "reports the refresh" "[file->file]"
cond "the first copy is refreshed" has_content "$F/tree/files/a/src.conf" "FRESH"
cond "the nested copy is refreshed" has_content "$F/tree/files/b/src.conf" "FRESH"
cond "an unrelated name is untouched" has_content "$F/tree/other/other.conf" "keep"
cond "destination mode is preserved" test "$(mode_of "$F/tree/files/b/src.conf")" = "600"
cond "the source is only ever read" test "$source_sum" = "$(cksum < "$F/src.conf")"

# ------------------------------------------------------------------------------
section "file mode: symlink targets"

mkfix "$FX/symtarget"
S="$FX/symtarget"

ran_ok "a link target becomes a real file" bash "$SUT" -d "$S/tree/links" "$S/src.conf"
says "reports the conversion" "[symlink->file]"
cond "the target is a regular file" is_real_file "$S/tree/links/src.conf"
cond "the target holds the fresh content" has_content "$S/tree/links/src.conf" "FRESH"

ran_ok "a dangling link target becomes a real file" bash "$SUT" -d "$S/tree/dangling" "$S/src.conf"
cond "the dangling target is a regular file" is_real_file "$S/tree/dangling/src.conf"
cond "the dangling target is no longer a link" test ! -L "$S/tree/dangling/src.conf"

mkdir -p "$S/pointers"
ln -s ../src.conf "$S/pointers/src.conf"
ran_ok "a link to the source is replaced" bash "$SUT" -d "$S/pointers" "$S/src.conf"
cond "the link to the source became a real file" is_real_file "$S/pointers/src.conf"

mkdir -p "$S/dirlink/targetdir"
ln -s targetdir "$S/dirlink/src.conf"
ran_ok "a link-to-directory target becomes a file" bash "$SUT" -d "$S/dirlink" "$S/src.conf"
cond "the directory link became a real file" is_real_file "$S/dirlink/src.conf"

# ------------------------------------------------------------------------------
section "skip rules"

mkfix "$FX/skip"
K="$FX/skip"

ran_ok "the source itself is skipped" bash "$SUT" -d "$K/tree/files/a" "$K/tree/files/a/src.conf"
says "the source counts as skipped" "0 real file(s) and 0 symlink(s); 1 skipped"
cond "the source still holds its content" has_content "$K/tree/files/a/src.conf" "old-a"

mkdir -p "$K/hard"
ln "$K/src.conf" "$K/hard/src.conf"
ran_ok "a hardlink to the source is skipped" bash "$SUT" -d "$K/hard" "$K/src.conf"
says "the hardlink counts as skipped" "0 real file(s) and 0 symlink(s); 1 skipped"

mkdir -p "$K/tree/alias"
ln -s ../../../src.conf "$K/tree/alias/src.conf"
ran_ok "a different link to the source is not skipped" bash "$SUT" -d "$K/tree/alias" "$K/src.conf"
cond "the alias link became a real file" is_real_file "$K/tree/alias/src.conf"

# ------------------------------------------------------------------------------
section "symlink mode: verbatim link text"

mkfix "$FX/linkmode"
L="$FX/linkmode"
printf 'plain\n' > "$L/tree/files/a/link.conf"
mkdir -p "$L/tree/links2" "$L/tree/dangling2"
ln -s /etc/hostname "$L/tree/links2/link.conf"
ln -s ../nowhere "$L/tree/dangling2/link.conf"

ran_ok "a real file becomes a link" bash "$SUT" -d "$L/tree/files/a" "$L/link.conf"
says "reports the conversion" "[file->link]"
cond "the target is a link with the source's text" is_link_to "$L/tree/files/a/link.conf" "target.txt"

ran_ok "an existing link is recreated" bash "$SUT" -d "$L/tree/links2" "$L/link.conf"
cond "the link is recreated verbatim" is_link_to "$L/tree/links2/link.conf" "target.txt"

ran_ok "a dangling target link is recreated" bash "$SUT" -d "$L/tree/dangling2" "$L/link.conf"
cond "the dangling link is recreated verbatim" is_link_to "$L/tree/dangling2/link.conf" "target.txt"
says "the summary counts links" "0 real file(s) and 1 symlink(s)"

# ------------------------------------------------------------------------------
section "symlink mode: absolute destinations (-a)"

mkfix "$FX/abs"
A="$FX/abs"
printf 'plain\n' > "$A/tree/files/a/link.conf"

ran_ok "-a writes the absolute destination" bash "$SUT" -a -d "$A/tree/files/a" "$A/link.conf"
cond "the target resolves to the source destination" is_link_to "$A/tree/files/a/link.conf" "$A/target.txt"
says_not "-a run warns about dangling links" "dangling"

mkdir -p "$A/chainverbatim"
ln -s ../nowhere "$A/chainverbatim/chain.conf"
ran_ok "a chained link is copied verbatim by default" bash "$SUT" -d "$A/chainverbatim" "$A/chain.conf"
cond "the chained link keeps the intermediate text" is_link_to "$A/chainverbatim/chain.conf" "mid.conf"

mkdir -p "$A/chainabsolute"
ln -s ../nowhere "$A/chainabsolute/chain.conf"
ran_ok "-a flattens a chained link" bash "$SUT" -a -d "$A/chainabsolute" "$A/chain.conf"
cond "the chained link resolves fully" is_link_to "$A/chainabsolute/chain.conf" "$A/target.txt"

# ------------------------------------------------------------------------------
section "symlink source edge cases"

mkfix "$FX/linkedge"
E="$FX/linkedge"
mkdir -p "$E/tree/edge"
printf 'old\n' > "$E/tree/edge/dangle.conf"

ran_ok "a dangling source is accepted" bash "$SUT" -d "$E/tree/edge" "$E/dangle.conf"
says "the dangling source warns" "dangling symlink"
cond "the target is a dangling link" is_dangling_link "$E/tree/edge/dangle.conf"
says "the created dangling link is reported" "created link is dangling"

ran_ok "-a on a dangling source is accepted" bash "$SUT" -a -d "$E/tree/edge" "$E/dangle.conf"
cond "-a writes the absolute intended destination" is_link_to "$E/tree/edge/dangle.conf" "$E/nowhere.conf"

ln -s tree "$E/dirlink.conf"
mkdir -p "$E/tree/edgedir"
printf 'old\n' > "$E/tree/edgedir/dirlink.conf"
ran_ok "a link-to-directory source is accepted" bash "$SUT" -d "$E/tree/edgedir" "$E/dirlink.conf"
says "the directory link source warns" "points to a directory"
cond "the target became a directory link" is_link_to "$E/tree/edgedir/dirlink.conf" "tree"

# ------------------------------------------------------------------------------
section "literal names"

mkfix "$FX/literal"
T="$FX/literal"
printf 'BRACKET\n' > "$T/src[1].conf"

ran_ok "a bracketed name is matched literally" bash "$SUT" -d "$T/tree/glob" "$T/src[1].conf"
cond "the bracketed target is replaced" has_content "$T/tree/glob/src[1].conf" "BRACKET"
cond "the near-miss name is untouched" has_content "$T/tree/glob/src1.conf" "old-g2"

printf 'SPACE\n' > "$T/sp ace.conf"
mkdir -p "$T/tree/space"
printf 'old\n' > "$T/tree/space/sp ace.conf"
ran_ok "a name with a space is replaced" bash "$SUT" -d "$T/tree/space" "$T/sp ace.conf"
cond "the spaced target holds the fresh content" has_content "$T/tree/space/sp ace.conf" "SPACE"

NL=$'na\nme.conf'
printf 'NEWLINE\n' > "$T/$NL"
mkdir -p "$T/tree/newline"
printf 'old\n' > "$T/tree/newline/$NL"
ran_ok "a name with a newline is replaced" bash "$SUT" -d "$T/tree/newline" "$T/$NL"
cond "the newline target holds the fresh content" has_content "$T/tree/newline/$NL" "NEWLINE"

# ------------------------------------------------------------------------------
section "search root"

mkfix "$FX/root"
R="$FX/root"
ran_ok "a relative -d resolves from another cwd" \
    bash -c "cd '$R' && bash '$SUT' -d ./tree/files/a ./src.conf"
cond "the relative-root target is replaced" has_content "$R/tree/files/a/src.conf" "FRESH"

mkfix "$FX/root2"
R2="$FX/root2"
ran_ok "the default root is the current directory" \
    bash -c "cd '$R2/tree/files/a' && bash '$SUT' '$R2/src.conf'"
cond "the default-root target is replaced" has_content "$R2/tree/files/a/src.conf" "FRESH"

mkfix "$FX/root3"
R3="$FX/root3"
ran_ok "--dir=DIR form works" bash "$SUT" --dir="$R3/tree/files" "$R3/src.conf"
cond "the equals-form target is replaced" has_content "$R3/tree/files/b/src.conf" "FRESH"

mkfix "$FX/root4"
R4="$FX/root4"
ran_ok "options after the source still parse" bash "$SUT" "$R4/src.conf" -d "$R4/tree/files"
cond "the post-source -d target is replaced" has_content "$R4/tree/files/a/src.conf" "FRESH"

mkfix "$FX/dash"
D="$FX/dash"
printf 'DASH\n' > "$D/-weird.conf"
mkdir -p "$D/tree/dash"
printf 'old\n' > "$D/tree/dash/-weird.conf"
ran_ok "-- allows a dash-leading source" \
    bash -c "cd '$D' && bash '$SUT' -d tree/dash -- -weird.conf"
cond "the dash-leading target is replaced" has_content "$D/tree/dash/-weird.conf" "DASH"

# ------------------------------------------------------------------------------
section "dry run writes nothing"

mkfix "$FX/dry"
Y="$FX/dry"
printf 'changed\n' > "$Y/tree/files/a/src.conf"

ran_ok "-t exits 0" bash "$SUT" -t -d "$Y/tree/files" "$Y/src.conf"
says "-t announces itself" "TEST MODE"
says "-t reports would replace" "would replace"
cond "-t leaves the content alone" has_content "$Y/tree/files/a/src.conf" "changed"
cond "-t leaves links alone" is_link_to "$Y/tree/links/src.conf" "../../../src.conf"

ran_ok "--dry-run is an alias" bash "$SUT" --dry-run -d "$Y/tree/files" "$Y/src.conf"
says "--dry-run announces itself" "TEST MODE"

printf 'plain\n' > "$Y/tree/files/b/link.conf"
ran_ok "-t in link mode exits 0" bash "$SUT" -t -d "$Y/tree/files/b" "$Y/link.conf"
says "-t in link mode says would replace" "would replace [file->link]"
cond "-t created no link" is_real_file "$Y/tree/files/b/link.conf"

# ------------------------------------------------------------------------------
section "nothing to match"

mkfix "$FX/none"
ran_ok "a tree without a match exits 0" bash "$SUT" -d "$FX/none/tree/other" "$FX/none/src.conf"
says "the empty result is reported" "no match for 'src.conf'"
says "the summary counts zero" "0 real file(s) and 0 symlink(s)"

# ------------------------------------------------------------------------------
section "failures"

if ((EUID != 0)); then
    mkfix "$FX/ro"
    P="$FX/ro"
    chmod 555 "$P/tree/files/a"
    chmod 444 "$P/tree/files/a/src.conf"
    ran_no "a failed copy exits 1" bash "$SUT" -d "$P/tree/files/a" "$P/src.conf"
    says "the failed copy is reported" "failed to copy"
    chmod 755 "$P/tree/files/a"
    chmod 644 "$P/tree/files/a/src.conf"

    mkfix "$FX/unreadable"
    U="$FX/unreadable"
    mkdir -p "$U/tree/locked"
    printf 'x\n' > "$U/tree/locked/src.conf"
    chmod 000 "$U/tree/locked"
    ran_no "an unreadable subtree exits 1" bash "$SUT" -d "$U/tree" "$U/src.conf"
    says "find's complaint is reported" "Permission denied"
    chmod 755 "$U/tree/locked"
else
    note "    (running as root: permission-based checks skipped)"
fi

# ------------------------------------------------------------------------------
section "the repository is left alone"

cond "the script under test is unchanged" \
    test "$(cd "$SUT_DIR" && find . \( -type f -o -type l \) | sort)" = "$DIR_SNAPSHOT"

# ==============================================================================
note ""
$QUIET || printf '%b%s%b\n' "$CYAN" \
    "----------------------------------------------------------------------" "$RESET"

if ((FAILED > 0)); then
    printf '%b  %d passed, %d FAILED%b\n' "$RED" "$PASSED" "$FAILED" "$RESET"
    exit 1
fi
printf '%b  %d passed%b\n' "$GREEN" "$PASSED" "$RESET"
exit 0
