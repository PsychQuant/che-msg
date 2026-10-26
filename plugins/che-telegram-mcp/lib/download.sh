#!/bin/bash
# Downloading and installing a pinned che-telegram-mcp binary
# (PsychQuant/che-msg#56). Both wrappers in bin/ source this file. The download
# itself runs in a process of its own, `/bin/bash download.sh fetch …`, so that
# the lock below names that process and nothing else.
#
# It runs in the background, off the startup path (PsychQuant/che-msg#67).
# Claude Code waits about 30 seconds for a server to answer initialize, and
# the telegram-all binary is about 240 MB: a download on the startup path was
# stopped with the wrapper before it could be moved into place, and the next
# start began again. download_start runs it in a session of its own, so it
# outlives the wrapper and a signal to the wrapper's process group; its output
# goes to ~/bin/.<Binary>.download.log. The wrappers wait for it a few seconds
# (download_wait) only when there is no binary they can run meanwhile.
#
# What a download does, and why:
# - It fails on an HTTP error (curl -f). `curl -sL` exits 0 with the error
#   page, which the wrappers installed as the binary and recorded as the
#   pinned version, so no later start downloaded again.
# - It resumes. It writes to a partial file named after the version,
#   ~/bin/.<Binary>.<version>.part, with `curl -C -`, so a transfer cut off
#   here or in an earlier start continues where it stopped. A partial file of
#   another version is removed, never joined to this one.
# - It retries a transfer that stops, up to three more times, each resuming
#   where the last one stopped, and gives up only on a stall (--speed-limit /
#   --speed-time). A cap on the whole transfer, as --max-time was, cannot be
#   met on a slow link: the 238 MB telegram-all binary takes about 17 minutes
#   at 234 KB/s. An HTTP error is not retried (curl's --retry-all-errors would
#   retry a 404 too, for seconds that a first install does not wait), so a
#   release without the asset is reported at once.
# - It has one writer. The download runs holding an flock on
#   ~/bin/.<Binary>.download.lock, taken by perl before it execs the download,
#   so the downloading process and everything it starts (curl, shasum, mv)
#   hold it: the partial file is written, hashed, made executable and moved
#   into place under the same lock. A second download that finds the lock
#   held exits at once ("download already running"). The kernel releases an
#   flock when the last process holding it exits, so a lock can never be left
#   behind by a download that was killed and there is nothing to take over.
#   Two wrappers started together both wrote ~/bin/<Binary>.tmp before, and
#   curl truncates its output file when it opens it, so the second emptied
#   what the first was still writing.
# - It installs nothing it has not checked (PsychQuant/che-msg#50). The
#   finished file's sha256 must equal the one the wrapper pins next to
#   DESIRED_VERSION (SHA256_PIN, used only while SHA256_PIN_VERSION equals the
#   version downloaded). Without such a pin, the sha256 digest GitHub's release
#   API reports for the asset is used. That digest comes from the same place as
#   the asset, so it catches a damaged, cut-off or wrongly resumed file but not
#   a replaced asset; only the pin does that. With neither, nothing is
#   downloaded. A file that does not match is removed.
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

# download_start <binary name> <version> <url> <install dir> <pin version>
# <pin> <release API url>: starts downloading and installing that version in
# the background and returns at once; sets DOWNLOAD_PID. perl (which macOS
# ships, and which shasum needs anyway) puts the download in a session of its
# own (macOS has no setsid command), takes the download lock without waiting
# (exit 10 when it is held: "download already running"), keeps the lock's file
# descriptor open across exec, and execs `download.sh fetch`.
download_start() {
    local log="$4/.$1.download.log" lock="$4/.$1.download.lock"
    mkdir -p "$4" 2>/dev/null
    nohup perl -MPOSIX -MFcntl=:flock,F_SETFD -e '
        POSIX::setsid();
        my $lock = shift;
        open(my $fh, ">>", $lock) or do { print STDERR "cannot open the download lock $lock: $!\n"; exit 70 };
        flock($fh, LOCK_EX | LOCK_NB) or do { print STDERR "download already running: another process holds $lock\n"; exit 10 };
        fcntl($fh, F_SETFD, 0) or exit 71;
        exec @ARGV or exit 71;
    ' "$lock" /bin/bash "$DOWNLOAD_LIB" fetch "$@" </dev/null >>"$log" 2>&1 &
    DOWNLOAD_PID=$!
}

# download_wait <binary name> <version> <install dir> <seconds>: waits up to
# <seconds> for that version to be installed, by the download download_start
# started or, when that found another one running (status 10), by the other.
# Sets DOWNLOAD_STATE to installed, failed or running, and DOWNLOAD_STATUS to
# the download's exit status once it has ended.
download_wait() {
    local name=$1 version=$2 dir=$3 deadline=$((SECONDS + $4))
    DOWNLOAD_STATE=running
    DOWNLOAD_STATUS=""
    while :; do
        if [[ -z "$DOWNLOAD_STATUS" ]] && ! kill -0 "$DOWNLOAD_PID" 2>/dev/null; then
            wait "$DOWNLOAD_PID" 2>/dev/null
            DOWNLOAD_STATUS=$?
        fi
        if [[ -x "$dir/$name" ]] && version_at_least "$(read_version_record "$dir/.$name.version")" "$version"; then
            DOWNLOAD_STATE=installed
            return 0
        fi
        if [[ -n "$DOWNLOAD_STATUS" && "$DOWNLOAD_STATUS" != 10 ]]; then
            DOWNLOAD_STATE=failed
            return 0
        fi
        [[ "$SECONDS" -ge "$deadline" ]] && return 0
        sleep 0.1
    done
}

# install_wait_seconds <default>: how long a wrapper with no binary to run
# waits for its download before answering: CHE_TELEGRAM_MCP_INSTALL_WAIT when
# it is a whole number of seconds up to 600, otherwise <default>. A longer wait
# helps only if Claude Code waits longer too (its MCP_TIMEOUT).
install_wait_seconds() {
    local v=${CHE_TELEGRAM_MCP_INSTALL_WAIT:-}
    if [[ "$v" =~ ^[0-9]{1,3}$ ]] && [[ $((10#$v)) -le 600 ]]; then echo $((10#$v)); else echo "$1"; fi
}

# download_progress <binary name> <version> <install dir>: ", N MB so far" for
# the partial file of that version, or nothing when there is none yet.
download_progress() {
    local bytes
    bytes=$(stat -f %z "$3/.$1.$2.part" 2>/dev/null) || return 0
    [[ "$bytes" =~ ^[0-9]+$ ]] && [[ "$bytes" -gt 0 ]] && echo ", $((bytes / 1048576)) MB so far"
    return 0
}

# download_failure <status>: why a download installed nothing, as a phrase for
# the wrappers' messages. It has no double quotes or backslashes, so the
# telegram-all wrapper can put it in its JSON-RPC error unescaped.
download_failure() {
    case "$1" in
        10) echo "another session is downloading it" ;;
        70|71) echo "the download could not be started (see its log)" ;;
        127) echo "perl, which the download needs, was not found" ;;
        20) echo "the transfer was interrupted; the next start resumes it" ;;
        21) echo "the server answered with an HTTP error, so the release or its asset may not exist" ;;
        23) echo "GitHub could not be reached to look up its sha256; the next start tries again" ;;
        30) echo "no sha256 is known to check it against: this plugin pins none for this version, and GitHub reported no digest for the asset" ;;
        31) echo "the downloaded file does not match its sha256, so it was removed" ;;
        40) echo "the downloaded file could not be put in place in ~/bin" ;;
        *)  echo "the download stopped with status $1" ;;
    esac
}

# download_manual_hint <binary name> <version> <url> <pin version> <pin>: the
# commands to install that version by hand, on stderr. The file goes to
# ~/bin/<Binary>.new and is moved into place in one step, so a session running
# the old binary keeps it; curl -C - continues a download that stopped.
download_manual_hint() {
    local name=$1 version=$2 url=$3 expected="the sha256 shown for $1 on the v$2 release page"
    [[ "$4" == "$2" && -n "$5" ]] && expected=$5
    echo "  To install it by hand (see Manual install in the che-telegram-mcp README):" >&2
    echo "    curl -fL -C - $url -o ~/bin/$name.new" >&2
    echo "    shasum -a 256 ~/bin/$name.new    # must print $expected" >&2
    echo "    chmod +x ~/bin/$name.new && mv ~/bin/$name.new ~/bin/$name && echo $version > ~/bin/.$name.version" >&2
}

# ------------------------------------------------------------ the checksum

# _dl_sha256 <file>: the file's sha256 in lowercase hex.
_dl_sha256() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; }

# _dl_api_digest <release API url> <binary name>: the sha256 GitHub reports for
# that asset of the release, or nothing (no such asset, or "digest": null).
# Exit status: curl's, so a failed lookup is not mistaken for a missing digest.
# The JSON is split at commas first, so a compact response reads as GitHub's
# pretty-printed one; an asset's digest comes before its download URL.
_dl_api_digest() {
    local json
    json=$(curl -fsSL --retry 2 --connect-timeout 30 --max-time 60 "$1") || return $?
    printf '%s\n' "$json" | tr ',' '\n' | awk -v name="$2" '
        /"digest"[[:space:]]*:/ {
            d = $0
            if (sub(/.*"digest"[[:space:]]*:[[:space:]]*"sha256:/, "", d)) { sub(/".*/, "", d); digest = d } else digest = ""
            next
        }
        /"browser_download_url"[[:space:]]*:/ {
            if (index($0, "/" name "\"") > 0) { print digest; exit }
            digest = ""
        }'
}

# ------------------------------------------------------------ the download

# download_fetch <binary name> <version> <url> <install dir> <pin version>
# <pin> <release API url>: runs in the process download_start starts, which
# holds the download lock (status 10, "download already running", comes from
# download_start when it does not get it). Exit status:
#   0   installed, or another process installed this version meanwhile
#   20  the transfer failed; the partial file is kept for the next attempt
#   21  the server answered with an HTTP error; the partial file is removed
#   23  the release API could not be reached; nothing was downloaded
#   30  no sha256 to check the download against; nothing was downloaded
#   31  the download does not match its sha256; it was removed
#   40  the downloaded file could not be put in place
download_fetch() {
    local name=$1 version=$2 url=$3 dir=$4 pin_version=${5:-} pin=${6:-} api_url=${7:-}
    local binary="$dir/$name" record="$dir/.$name.version"
    local part="$dir/.$name.$version.part" f rc expected checked_against attempt

    mkdir -p "$dir" || return 40
    # curl and the pauses between attempts are stopped with this process.
    # They hold the lock too (they inherit its descriptor), so a transfer
    # that outlived this process would keep any other download out.
    DL_CURL=""
    trap '[ -n "$DL_CURL" ] && kill "$DL_CURL" 2>/dev/null' EXIT
    trap 'exit 143' TERM INT
    # The log collects every session's downloads; keep it short.
    f="$dir/.$name.download.log"
    [[ -f "$f" ]] && [[ "$(wc -c < "$f" 2>/dev/null)" -gt 262144 ]] && : > "$f"
    echo "$(date '+%Y-%m-%d %H:%M:%S %z') $name: downloading v$version (process $$)" >&2

    # The wrapper decided to download before the lock was taken; another
    # process may have installed this version since.
    if [[ -x "$binary" ]] && version_at_least "$(read_version_record "$record")" "$version"; then
        return 0
    fi

    for f in "$dir/.$name."*.part; do
        [ "$f" = "$part" ] || rm -f "$f"
    done

    # The sha256 the result must have, known before anything is downloaded.
    if [[ -n "$pin" && "$pin_version" != "$version" ]]; then
        echo "$name: the sha256 this plugin pins is for v$pin_version, not v$version, so it is not used; checking against GitHub's digest instead" >&2
        pin=""
    fi
    if [[ -n "$pin" ]]; then
        if ! [[ "$pin" =~ ^[0-9a-f]{64}$ ]]; then
            echo "$name: the sha256 this plugin pins for v$version is not 64 lowercase hex digits; nothing was downloaded" >&2
            return 30
        fi
        expected=$pin
        checked_against="the sha256 this plugin pins"
    else
        expected=$(_dl_api_digest "$api_url" "$name"); rc=$?
        case "$rc" in
            0) ;;
            22) echo "$name: GitHub's release API answered $api_url with an HTTP error; nothing was downloaded" >&2
                return 21 ;;
            *)  echo "$name: GitHub's release API could not be reached (curl exit status $rc); nothing was downloaded" >&2
                return 23 ;;
        esac
        if ! [[ "$expected" =~ ^[0-9a-f]{64}$ ]]; then
            echo "$name: v$version has no pinned sha256 and GitHub reported no digest for its asset; nothing was downloaded" >&2
            return 30
        fi
        checked_against="the sha256 digest GitHub reports for the asset"
    fi

    if [[ -f "$part" ]] && [[ "$(_dl_sha256 "$part")" == "$expected" ]]; then
        # Complete already: an earlier download finished but was stopped
        # before its move (#67).
        echo "$name: the partial file of v$version is complete and matches; installing it without downloading again" >&2
    else
        # curl and the pause run in the background with wait, so that a TERM
        # stops them at once instead of after they finish. curl's own --retry
        # covers what it calls transient (timeouts, HTTP 408, 429, 5xx); the
        # loop covers a connection that is reset or drops, which --retry
        # alone does not.
        for attempt in 1 2 3 4; do
            curl -fsSL --retry 2 --connect-timeout 30 \
                --speed-limit 4096 --speed-time 60 -C - -o "$part" "$url" &
            DL_CURL=$!
            wait "$DL_CURL"; rc=$?
            DL_CURL=""
            case "$rc" in 0|22|33) break ;; esac
            [ "$attempt" = 4 ] && break
            echo "$name: the transfer stopped (curl exit status $rc); resuming it (retry $attempt of 3)" >&2
            sleep 2 & DL_CURL=$!; wait "$DL_CURL"; DL_CURL=""
        done
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
    fi

    f=$(_dl_sha256 "$part")
    if [[ "$f" != "$expected" ]]; then
        rm -f "$part"
        echo "$name: the download of v$version has sha256 ${f:-unknown}, not $expected ($checked_against); it was removed and nothing was installed" >&2
        return 31
    fi

    if ! chmod +x "$part" || ! mv -f "$part" "$binary"; then
        echo "$name: the download could not be moved into place at $binary" >&2
        return 40
    fi
    if ! printf '%s\n' "$version" > "$record.$$" || ! mv -f "$record.$$" "$record"; then
        rm -f "$record.$$"
        echo "$name: v$version is installed, but its version record $record could not be written" >&2
        return 40
    fi
    echo "$name: installed v$version (sha256 checked against $checked_against)" >&2
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        fetch) shift; download_fetch "$@"; exit $? ;;
        *) echo "usage: download.sh fetch <binary name> <version> <url> <install dir> <pin version> <pin> <release API url>" >&2; exit 2 ;;
    esac
fi
