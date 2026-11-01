# replace_files

Recursively walks a directory tree and replaces every file or symlink whose basename matches a given (set of) source file(s) with a fresh copy or recreated link, so that after a run the targets always take on the source's kind (real file vs. symlink).

**Version:** 1.1 · **Author:** Gino Bogo · **License:** MIT

## Contents

- [Purpose](#purpose)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Usage](#usage)
- [Options](#options)
- [Arguments](#arguments)
- [Replacement Rules](#replacement-rules)
- [How It Works](#how-it-works)
- [Skip Rules](#skip-rules)
- [Exit Codes](#exit-codes)
- [Counters & Summary](#counters--summary)
- [Examples](#examples)
- [Behavioral Notes](#behavioral-notes)
- [Testing](#testing)
- [License](#license)

## Purpose

`replace_files.sh` is a bulk refresh tool. Given one or more source files, it scans a directory tree and, for every entry (regular file **or** symlink) whose **basename** equals a source's basename, replaces it so its content and kind match the source:

- A real-file source is **copied** in place into each matching target.
- A symlink source is **recreated** with the source link's text (verbatim by default, or its resolved absolute destination with `-a`).

This is useful for keeping many copies of a config file (e.g. `.clang-format`, `Makefile`, shared headers) in sync across a tree, or for turning a fleet of copies into symlinks to a single shared file.

## Requirements

- **Bash 4.0+** (uses associative arrays; checked at startup, exits 2 otherwise).
- Standard POSIX-ish userland, with these commands available: `find`, `cp`, `ln`, `rm`, `basename`, `dirname`, `readlink`, `mktemp`.
- All are validated at startup; a missing one exits with code `3`.
- Linux/macOS environments where GNU `readlink -f` semantics are available (used by `-a`).

## Installation

No build step. The script is self-contained and executable:

```sh
chmod +x replace_files.sh
```

Run it in place, or symlink/copy it onto your `$PATH`. Two companion files are shipped alongside it:

- `replace_files.sh` — the tool itself.
- `tests/test_replace_files.sh` — the regression suite (reads only; never writes into the repo).

## Quick Start

Refresh every copy of a shared config under a project tree:

```sh
./replace_files.sh -d ~/Projects/shared-config.conf ~/Projects
```

Dry-run first to see what would change:

```sh
./replace_files.sh -t -d ./project ./shared/.clang-format
```

## Usage

```text
replace_files.sh [options] <source-file>...
```

Sources are **positional**; options may appear before, between, or after sources (getopt-style parsing in a `while` loop). Use `--` to separate options from source paths that begin with `-`.

## Options

| Flag | Long form | Description |
| --- | --- | --- |
| `-d DIR` | `--dir DIR` / `--dir=DIR` | Search root. Defaults to the current working directory. |
| `-t` | `--test` / `--dry-run` | Dry run — print what would change without modifying anything. |
| `-a` | `--absolute-link` | When the source is a symlink, recreate links using its **absolute resolved destination** instead of verbatim link text. |
| `-h` | `--help` | Show help and exit 0. |
| `-V` | `--version` | Show version and exit 0. |
| `--` | | End of options (for sources whose path starts with `-`). |

## Arguments

`<source-file>...` — one or more real files **or** symlinks whose basenames are matched across the tree. Repeating a path twice collapses to a single replacement (with a warning); see [Duplicate Sources](#duplicate-sources).

Each source is classified by kind:

- `[[ -L ]]` → **LINK** mode (even if dangling — `-L` is tested before `-f`).
- otherwise `[[ -f ]]` → **FILE** mode.
- a directory or any other file type → rejected (exit 2).
- a non-existent path → rejected (exit 2).

Glob metacharacters in a source's basename (`*`, `?`, `[`, `]`, `\`) are treated **literally** during the scan (escaped internally by `glob_escape` before being handed to `find -name`).

## Replacement Rules

| Source kind | Target kind | Result |
| --- | --- | --- |
| Real file | Real file | Content replaced (`cp -f`); destination **mode/owner** preserved while it can be written in place. |
| Real file | Symlink  | Link removed; a real file takes its place. |
| Symlink  | Real file | File removed; source link recreated. |
| Symlink  | Symlink  | Link removed; source link recreated. |

In other words, the target always ends up carrying the source's kind.

If a real-file target is not writable but its directory is, `cp -f` unlinks and
recreates it, so the new file takes the **source's** mode rather than the old
target's mode.

## How It Works

1. **Argument parsing** — options and sources collected; at least one source required.
2. **Source validation** — each source resolved to a physical absolute path (`cd … && pwd -P`); mode detected; symlink destination read via `readlink`; dangling/points-to-directory warnings emitted; with `-a`, destination resolved via `readlink -f` (chained links fully resolved, including dangling final component when its parent exists).
3. **Duplicate detection** (associative arrays):
   - The **same path twice** → warning, treated once.
   - **Two different files sharing a basename** → error, exit 2 (matching is by name, so one would silently win).
4. **Scan** — for each source:
   ```sh
   find "$SEARCH_ABS" \( -type f -o -type l \) -name "$pattern" -print0
   ```
   - `find` does **not** follow symlinks, so directories reached via a symlink are not visited, and symlinked entries are tested by their own type.
   - Null-delimited output; `read -d ''` so spaces, globs, and newlines in names survive.
   - Unreadable subtrees are reported via `find`'s stderr (captured to a temp file) instead of vanishing silently.
5. **Replace** — `replace_match` for each hit, with self/source hardlink guards.
6. **Summary** printed; exit code set.

## Skip Rules

A candidate is **not** touched (counted as skipped) when:

- Its resolved path string **equals** the source's resolved path — the source is never its own target.
- In **FILE** mode, the candidate is a real (non-symlink) file that is the **same inode** as the source (`-ef`). This prevents `cp -f` from clobbering the source when both names resolve to one file via a hardlink or a different spelling of the same path. Symlinks pointing at the source are **not** skipped — replacing such a link is legitimate and never touches the source's bytes.

## Counters & Summary

Counters tally over the whole run:

- `FILE_COUNT` — targets that ended as real files (also FILE-mode test entries).
- `LINK_COUNT` — targets that ended as symlinks.
- `SKIP_COUNT` — targets skipped per the rules above.
- `WARN_COUNT` — warnings issued.
- `FAIL_COUNT` — failed copy/link operations.

Final line:

```text
Replaced N real file(s) and M symlink(s); K skipped.
```

In test mode the run also prints `TEST MODE: no files were modified` / `would replace …`.

## Exit Codes

| Code | Meaning |
| --- | --- |
| `0` | Success (warnings allowed). A clean run that replaced nothing still exits 0 (explicitly set, not inherited). |
| `1` | At least one copy/link operation or directory scan failed. |
| `2` | Bad usage or an unusable input (missing/unknown option, missing source, directory/fifo source, duplicate basename, unreadable source, unreadable search root, bad search dir, Bash < 4). |
| `3` | A required external command is missing. |

## Behavioral Notes

- **Symlinks are never followed during the scan.** A target sitting inside a symlinked directory is not visited, and the source directory tree is not traversed via links.
- **The source itself is skipped** (and never copied onto itself), including when reached under another spelling as the same inode in file mode.
- **Byte-exact names:** source basenames, search roots and symlink text are handled exactly, including trailing newlines. Glob characters in a basename stay literal.
- **Mode/ownership:** when refreshing a writable real file with a real-file source, `cp -f` preserves the destination's existing mode (verified by tests); ownership follows `cp`'s default behavior. A read-only target in a writable directory is unlinked and recreated, so it adopts the source's mode instead.
- **Hardlinked targets:** `cp` truncates an existing target in place, so replacing a target that is hardlinked to another name also changes that other name.
- **Unreadable sources** are refused up front (exit `2`) for real-file sources, before any target is removed. A source that becomes unreadable mid-run, or a full destination filesystem, can still leave a removed symlink target missing.
- **Dangling source links** are accepted (with a warning); targets become dangling links too. With `-a`, a dangling source resolves to its intended destination as long as the parent directory exists (GNU `readlink -f`).
- **A source link pointing at a directory** is accepted (with a warning) — targets become directory links.
- **Verification:** after creating a link, the script checks `[[ -e "$target" ]]` and warns "created link is dangling" when it does not resolve.
- **Dry run:** predicts replacements but does not test write permissions. A real run can still fail where `-t` reported "would replace".
- **Color:** ANSI color codes are always emitted (no `--color` flag). Tests strip them.
- **Concurrency:** the script is single-threaded; no locking is provided. Running two instances against the same tree concurrently is unsafe.
- **Temps:** `find`'s stderr is captured in an `mktemp` file registered in `TMP_FILES` and removed via an `EXIT` trap (including on abort).

## Examples

Dry run over a project tree:

```sh
./replace_files.sh -t -d ./project ./shared/.clang-format
```

Refresh every `.clang-format` copy under a projects root:

```sh
./replace_files.sh -d ~/Projects ~/.config/clang-format
```

Turn same-named files into links to a shared file (absolute destinations):

```sh
./replace_files.sh -a -d ./project ./shared/config.json
```

Two names in one pass:

```sh
./replace_files.sh -d ./project ./shared/a.h ./shared/b.h
```

Dash-leading source path (use `--`):

```sh
cd ./project && ./replace_files.sh -d tree/dash -- -weird.conf
```

`--dir=DIR` form and post-source options:

```sh
./replace_files.sh --dir=./tree/files ./src.conf
./replace_files.sh ./src.conf -d ./tree/files
```

## Testing

Run the regression suite:

```sh
bash tests/test_replace_files.sh          # default
bash tests/test_replace_files.sh -q       # failures + summary only
bash tests/test_replace_files.sh -v       # verbose
```

The suite builds fresh fixture trees under a temp directory and never writes into the repository (it snapshots the repo file list and checks file contents and asserts they are unchanged). It exercises the CLI surface, file/symlink targets, skip rules, link modes (verbatim vs. `-a`), edge cases (dangling/directory sources), literal names with spaces/brackets/newlines, newline-exact names and link text, search-root forms (including `CDPATH` and symlinked roots), multiple/mixed sources, dry run, none/match, unreadable sources and roots, permission failures, exact exit codes, temp cleanup, and repository immutability.

## Disclaimer

This tool performs destructive, in-place replacements across an entire directory tree and follows no symlinks during the scan, but it can still overwrite or remove files. Always run a dry run (`-t` / `--dry-run`) first to review the planned changes, keep backups of anything irreplaceable, and verify the search root (`-d`) before executing. The software is provided "AS IS", without warranty of any kind, as stated in the LICENSE; the authors are not liable for data loss or any other damage resulting from its use.

## License

MIT — see [LICENSE](LICENSE).