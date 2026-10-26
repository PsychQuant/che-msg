#!/bin/bash
# Downloading and installing a pinned che-telegram-mcp binary
# (PsychQuant/che-msg#56). Both wrappers in bin/ source this file. The download
# itself runs in a process of its own, `/bin/bash download.sh fetch …`, so that
# the lock below names that process and nothing else.
#
# What a download does, and why:
# - It fails on an HTTP error (curl -f). `curl -sL` exits 0 with the error
#   page, which the wrappers installed as the binary and recorded as the
#   pinned version, so no later start downloaded again.
# - It resumes. It writes to a partial file named after the version,
#   ~/bin/.<Binary>.<version>.part, with `curl -C -`, so a transfer cut off
#   here or in an earlier start continues where it stopped. A partial file of
#   another version is removed, never joined to this one.
# - It retries (--retry 3 --retry-all-errors) and gives up only on a stall
#   (--speed-limit / --speed-time). A cap on the whole transfer, as
#   --max-time was, cannot be met on a slow link: the 238 MB telegram-all
#   binary takes about 17 minutes at 234 KB/s.
# - It has one writer. A lock, a symlink ~/bin/.<Binary>.download.lock whose
#   target is the downloading process's PID, lets one process at a time write
#   the partial file. Two wrappers started together both wrote
#   ~/bin/<Binary>.tmp before, and curl truncates its output file when it
#   opens it, so the second emptied what the first was still writing.
#
# The functions keep to bash 3.2, the /bin/bash the wrappers run with.

DOWNLOAD_LIB="${BASH_SOURCE[0]}"

# version_at_least <version> <minimum>: true when <version> is x.y.z and not older.
version_at_least() {
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] &&
    [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]
}

# read_version_record <file>: the version record's content with only the
# surrounding whitespace (a trailing CR included) removed. Whitespace inside
# stays, so "9. 0.0" or a second line fails the x.y.z check of version_at_least.
read_version_record() {
    local v=""
    [[ -f "$1" ]] && v=$(cat "$1" 2>/dev/null || true)
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    printf '%s' "$v"
}

# download_install <binary name> <version> <url> <install dir>: downloads and
# installs that version, waiting for the result; returns download_fetch's status.
download_install() {
    /bin/bash "$DOWNLOAD_LIB" fetch "$@"
}

# download_failure <status>: why a download installed nothing, as a phrase for
# the wrappers' messages. It has no double quotes or backslashes, so the
# telegram-all wrapper can put it in its JSON-RPC error unescaped.
download_failure() {
    case "$1" in
        10) echo "another session is downloading it" ;;
        20) echo "the transfer was interrupted; the next start resumes it" ;;
        21) echo "the server answered with an HTTP error, so the release or its asset may not exist" ;;
        40) echo "the downloaded file could not be put in place in ~/bin" ;;
        *)  echo "the download stopped with status $1" ;;
    esac
}

# ---------------------------------------------------------------- the lock

# _dl_live_owner <lock>: true when the lock names a running download. A PID
# that the system has given to another program since does not count.
_dl_live_owner() {
    local owner
    owner=$(readlink "$1" 2>/dev/null) || return 1
    [[ "$owner" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$owner" 2>/dev/null || return 1
    ps -o command= -p "$owner" 2>/dev/null | grep -q 'download\.sh fetch'
}

# _dl_take_lock <lock>: true when this process now holds the lock. A lock left
# by a download that no longer runs is taken over. Two processes that find the
# same stale lock at the same moment can both end up downloading; the partial
# file may then be damaged, which is why #50 checks the result before it is
# installed.
_dl_take_lock() {
    local owner
    ln -s "$$" "$1" 2>/dev/null && return 0
    _dl_live_owner "$1" && return 1
    owner=$(readlink "$1" 2>/dev/null)
    [ "$(readlink "$1" 2>/dev/null)" = "$owner" ] && rm -f "$1"
    ln -s "$$" "$1" 2>/dev/null
}

# _dl_release_lock <lock>: removes the lock if this process holds it.
_dl_release_lock() {
    [ "$(readlink "$1" 2>/dev/null)" = "$$" ] && rm -f "$1"
    return 0
}

# ------------------------------------------------------------ the download

# download_fetch <binary name> <version> <url> <install dir>: runs in the
# process `download.sh fetch` starts. Exit status:
#   0   installed, or another process installed this version meanwhile
#   10  another download holds the lock; nothing was done
#   20  the transfer failed; the partial file is kept for the next attempt
#   21  the server answered with an HTTP error; the partial file is removed
#   40  the downloaded file could not be put in place
download_fetch() {
    local name=$1 version=$2 url=$3 dir=$4
    local binary="$dir/$name" record="$dir/.$name.version"
    local part="$dir/.$name.$version.part" f rc

    mkdir -p "$dir" || return 40
    DL_LOCK="$dir/.$name.download.lock"
    if ! _dl_take_lock "$DL_LOCK"; then
        echo "$name: another process is downloading $name; not starting a second download" >&2
        DL_LOCK=""
        return 10
    fi
    # The lock goes when this process does, also when it is stopped; curl is
    # stopped with it, so no transfer outlives the lock it was started under.
    DL_CURL=""
    trap '[ -n "$DL_CURL" ] && kill "$DL_CURL" 2>/dev/null; [ -n "$DL_LOCK" ] && _dl_release_lock "$DL_LOCK"' EXIT
    trap 'exit 143' TERM INT

    # The wrapper decided to download before this process took the lock;
    # another process may have installed this version since.
    if [[ -x "$binary" ]] && version_at_least "$(read_version_record "$record")" "$version"; then
        return 0
    fi

    for f in "$dir/.$name."*.part; do
        [ "$f" = "$part" ] || rm -f "$f"
    done

    # In the background with wait, so that a TERM stops the transfer at once
    # instead of after curl finishes.
    curl -fsSL --retry 3 --retry-all-errors --retry-delay 2 --connect-timeout 30 \
        --speed-limit 4096 --speed-time 60 -C - -o "$part" "$url" &
    DL_CURL=$!
    wait "$DL_CURL"; rc=$?
    DL_CURL=""
    case "$rc" in
        0) ;;
        22)
            rm -f "$part"
            echo "$name: the server answered $url with an HTTP error; nothing was installed" >&2
            return 21 ;;
        33)
            # The server would not resume: start from zero next time.
            rm -f "$part"
            echo "$name: the download of v$version could not be resumed (curl exit status 33); the next start downloads it again" >&2
            return 20 ;;
        *)
            echo "$name: the download of v$version was interrupted (curl exit status $rc); the next start resumes it" >&2
            return 20 ;;
    esac

    if ! chmod +x "$part" || ! mv -f "$part" "$binary"; then
        echo "$name: the download could not be moved into place at $binary" >&2
        return 40
    fi
    if ! printf '%s\n' "$version" > "$record.$$" || ! mv -f "$record.$$" "$record"; then
        rm -f "$record.$$"
        echo "$name: v$version is installed, but its version record $record could not be written" >&2
        return 40
    fi
    echo "$name: installed v$version" >&2
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        fetch) shift; download_fetch "$@"; exit $? ;;
        *) echo "usage: download.sh fetch <binary name> <version> <url> <install dir>" >&2; exit 2 ;;
    esac
fi
