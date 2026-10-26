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
# goes to ~/bin/.che-telegram-mcp-download/<Binary>.log. The wrappers wait for
# it a few seconds (download_wait) only when there is no binary they can run
# meanwhile.
#
# Its files live in a private staging directory, ~/bin/.che-telegram-mcp-download
# (created with mode 700; one that is a symbolic link, not a directory, not the
# user's, or of any other mode is refused, not repaired): the lock, the log, the partial file and the version record's
# temporary copy. Nothing there is followed if it is a symbolic link: curl
# would append to a link's target, shasum would hash it and mv would install
# the link. A partial file, lock or log that is not a regular file is removed
# before use, and the finished file must still be a regular file when it is
# hashed and when it is moved into place.
#
# What a download does, and why:
# - It fails on an HTTP error (curl -f). `curl -sL` exits 0 with the error
#   page, which the wrappers installed as the binary and recorded as the
#   pinned version, so no later start downloaded again.
# - It resumes. It writes to a partial file named after the version,
#   <Binary>.<version>.part in the staging directory, with `curl -C -`, so a
#   transfer cut off
#   here or in an earlier start continues where it stopped. A partial file of
#   another version is removed, never joined to this one.
# - It retries a transfer the network stopped, up to three more times, each
#   resuming where the last one stopped, and gives up only on a stall
#   (--speed-limit /
#   --speed-time). A cap on the whole transfer, as --max-time was, cannot be
#   met on a slow link: the 238 MB telegram-all binary takes about 17 minutes
#   at 234 KB/s. An HTTP error is not retried (curl's --retry-all-errors would
#   retry a 404 too, for seconds that a first install does not wait), so a
#   release without the asset is reported at once.
# - It has one writer. The download runs holding an flock on <Binary>.lock in
#   the staging directory, taken by perl before it execs the download,
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
#   version downloaded). Without such a pin nothing is downloaded: the digest
#   GitHub reports next to an asset comes from the same place as the asset, so
#   a replaced asset would match it, and it is never used instead. A file that
#   does not match is removed.
#
# The functions keep to bash 3.2, the /bin/bash the wrappers run with.

DOWNLOAD_LIB="${BASH_SOURCE[0]}"
DOWNLOAD_STAGE_NAME=".che-telegram-mcp-download"

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

# download_pin_status <version> <pin version> <pin>: 0 when the pin is for
# <version> and is 64 lowercase hex digits; 30 when there is no pin for
# <version>; 32 when the pin for it is malformed.
download_pin_status() {
    [[ -n "$3" && "$2" == "$1" ]] || return 30
    [[ "$3" =~ ^[0-9a-f]{64}$ ]] || return 32
    return 0
}

# download_start <binary name> <version> <url> <install dir> <pin version>
# <pin>: starts downloading and installing that version in the background and
# returns at once; sets DOWNLOAD_PID. It starts nothing, returns 1 and sets
# DOWNLOAD_START_STATUS without a usable pin (download_pin_status's status),
# when the staging directory or a file in it is refused (42), and when another
# download holds the lock (10). perl (which macOS
# ships, and which shasum needs anyway) puts the download in a session of its
# own (macOS has no setsid command), takes the download lock without waiting
# (exit 10 when it is held: "download already running"), keeps the lock's file
# descriptor open across exec, and execs `download.sh fetch`.
download_start() {
    local stage log lock
    DOWNLOAD_PID=""
    DOWNLOAD_START_STATUS=""
    download_pin_status "$2" "$5" "$6" || { DOWNLOAD_START_STATUS=$?; return 1; }
    download_stage "$4" || { DOWNLOAD_START_STATUS=42; return 1; }
    stage=$DOWNLOAD_STAGE
    log="$stage/$1.log"
    lock="$stage/$1.lock"
    if ! _dl_clear_nonregular "$log" || ! _dl_clear_nonregular "$lock"; then
        DOWNLOAD_STAGE_PROBLEM="holds a $1 file that is not a regular file and cannot be removed"
        DOWNLOAD_START_STATUS=42
        return 1
    fi
    # Whether another download holds the lock, so that the wrapper can say so
    # instead of starting one that would stop at once. The download takes the
    # lock itself below, so a download starting in between is still caught.
    perl -MFcntl=:flock,O_WRONLY,O_APPEND,O_CREAT,O_NOFOLLOW -e '
        sysopen(my $fh, $ARGV[0], O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0600) or exit 0;
        flock($fh, LOCK_EX | LOCK_NB) or exit 10;
        exit 0;' "$lock" 2>/dev/null
    if [[ $? == 10 ]]; then DOWNLOAD_START_STATUS=10; return 1; fi
    nohup perl -MPOSIX -MFcntl=:flock,F_SETFD,O_WRONLY,O_APPEND,O_CREAT,O_NOFOLLOW -e '
        POSIX::setsid();
        my $lock = shift;
        sysopen(my $fh, $lock, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0600) or do { print STDERR "cannot open the download lock $lock: $!\n"; exit 70 };
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
    if [[ -z "$DOWNLOAD_PID" ]]; then
        DOWNLOAD_STATUS=${DOWNLOAD_START_STATUS:-42}
        # Another download holds the lock: wait for it as for our own.
        [[ "$DOWNLOAD_STATUS" == 10 ]] || { DOWNLOAD_STATE=failed; return 0; }
    fi
    while :; do
        if [[ -z "$DOWNLOAD_STATUS" ]] && [[ -n "$DOWNLOAD_PID" ]] && ! kill -0 "$DOWNLOAD_PID" 2>/dev/null; then
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
    bytes=$(stat -f %z "$3/$DOWNLOAD_STAGE_NAME/$1.$2.part" 2>/dev/null) || return 0
    [[ "$bytes" =~ ^[0-9]+$ ]] && [[ "$bytes" -gt 0 ]] && echo ", $((bytes / 1048576)) MB so far"
    return 0
}

# download_failure <status> [version]: why a download installed nothing, as a
# phrase for the wrappers' messages. It has no double quotes or backslashes,
# so the wrappers can put it in their JSON-RPC error unescaped.
download_failure() {
    local v=${2:+v$2}
    case "$1" in
        10) echo "another process is downloading it already" ;;
        70|71) echo "the download could not be started (see its log)" ;;
        127) echo "perl, which the download needs, was not found" ;;
        20) echo "the transfer was interrupted; the next start resumes it" ;;
        21) echo "the server answered with an HTTP error: there is no such release asset (HTTP 404 or 410)" ;;
        25) echo "the server answered with an HTTP error other than 404 or 410 (for example a 5xx, 429, 401 or 403; the download log has the code); what was downloaded is kept and the next start tries again" ;;
        24) echo "the download failed for a reason other than the network (see its log)" ;;
        30) echo "this plugin has no sha256 for ${v:-this version}, so it downloads nothing it could not check: update or reinstall the che-telegram-mcp plugin" ;;
        32) echo "the sha256 this plugin pins for ${v:-this version} is malformed (not 64 lowercase hex digits), so it downloads nothing: update or reinstall the che-telegram-mcp plugin" ;;
        31) echo "the downloaded file does not match its sha256, so it was removed" ;;
        40) echo "the downloaded file could not be put in place in ~/bin" ;;
        42) echo "its staging directory ~/bin/$DOWNLOAD_STAGE_NAME ${DOWNLOAD_STAGE_PROBLEM:-or a file in it is not safe to use}: remove the directory (rm -rf ~/bin/$DOWNLOAD_STAGE_NAME) and reconnect, and the download creates it anew" ;;
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

# ---------------------------------------------------- the staging directory

# download_stage <install dir>: sets DOWNLOAD_STAGE to the private staging
# directory <install dir>/.che-telegram-mcp-download, creating it with mode
# 700. Fails, setting DOWNLOAD_STAGE_PROBLEM (a phrase for the wrappers'
# messages, without double quotes or backslashes) and saying it on stderr,
# when it is a symbolic link, not a directory, not the user's, or has any mode
# but 700. Such a directory is refused, never repaired: while it was open to
# others, anyone could have left a file in it and kept that file open for
# writing, and making the directory or the file private afterwards does not
# take back a descriptor already open. Removing it lets the next start create
# it anew, empty.
download_stage() {
    local stage="$1/$DOWNLOAD_STAGE_NAME" mode
    DOWNLOAD_STAGE=""
    DOWNLOAD_STAGE_PROBLEM=""
    mkdir -p "$1" 2>/dev/null
    [[ -e "$stage" || -L "$stage" ]] || mkdir -m 700 "$stage" 2>/dev/null
    if [[ -L "$stage" ]]; then
        DOWNLOAD_STAGE_PROBLEM="is a symbolic link"
    elif [[ ! -d "$stage" ]]; then
        DOWNLOAD_STAGE_PROBLEM="is not a directory"
    elif [[ ! -O "$stage" ]]; then
        DOWNLOAD_STAGE_PROBLEM="belongs to another user"
    else
        mode=$(stat -f %Lp "$stage" 2>/dev/null)
        [[ "$mode" == 700 ]] || DOWNLOAD_STAGE_PROBLEM="has mode ${mode:-unknown}, not 700, so files in it may not be the download's own"
    fi
    if [[ -n "$DOWNLOAD_STAGE_PROBLEM" ]]; then
        echo "che-telegram-mcp: $stage $DOWNLOAD_STAGE_PROBLEM; the download does not use it. Remove it (rm -rf ~/bin/$DOWNLOAD_STAGE_NAME) and reconnect: it is created anew." >&2
        return 1
    fi
    DOWNLOAD_STAGE=$stage
}

# _dl_regular <path>: a regular file, not a symbolic link.
_dl_regular() { [[ -f "$1" && ! -L "$1" ]]; }

# _dl_clear_nonregular <path>: removes <path> when it is a symbolic link or
# anything but a regular file; true when it is now absent or a regular file.
_dl_clear_nonregular() {
    if [[ -L "$1" ]] || { [[ -e "$1" ]] && ! _dl_regular "$1"; }; then
        echo "che-telegram-mcp: $1 is not a regular file; removing it" >&2
        rm -f "$1" 2>/dev/null
    fi
    if [[ -e "$1" || -L "$1" ]] && ! _dl_regular "$1"; then
        echo "che-telegram-mcp: $1 is not a regular file and cannot be removed; the download does not use it" >&2
        return 1
    fi
    return 0
}

# ------------------------------------------------------------ the checksum

# _dl_sha256 <file>: the file's sha256 in lowercase hex.
_dl_sha256() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; }

# ------------------------------------------------------------ the download

# download_fetch <binary name> <version> <url> <install dir> <pin version>
# <pin>: runs in the process download_start starts, which
# holds the download lock (status 10, "download already running", comes from
# download_start when it does not get it). Exit status:
#   0   installed, or another process installed this version meanwhile
#   20  the transfer failed; the partial file is kept for the next attempt
#   21  the server has no such asset (HTTP 404 or 410); the partial file is
#       removed
#   25  any other HTTP error (5xx, 429, 401, 403, …; 5xx and 429 after curl's own retries); the partial
#       file is kept for the next attempt
#   24  curl failed for a reason other than the network; the partial file
#       is kept
#   30  no pinned sha256 for this version; nothing was downloaded
#   31  the download does not match its sha256; it was removed
#   32  the pinned sha256 is malformed; nothing was downloaded
#   40  the downloaded file could not be put in place
#   42  the staging directory, or a file in it, is not safe to use
download_fetch() {
    local name=$1 version=$2 url=$3 dir=$4 pin_version=${5:-} pin=${6:-}
    local binary="$dir/$name" record="$dir/.$name.version"
    local stage part f rc expected checked_against attempt tmp code code_file

    download_stage "$dir" || return 42
    stage=$DOWNLOAD_STAGE
    part="$stage/$name.$version.part"
    # curl and the pauses between attempts are stopped with this process.
    # They hold the lock too (they inherit its descriptor), so a transfer
    # that outlived this process would keep any other download out.
    DL_CURL=""
    trap '[ -n "$DL_CURL" ] && kill "$DL_CURL" 2>/dev/null' EXIT
    trap 'exit 143' TERM INT
    # The log collects every session's downloads; keep it short.
    f="$stage/$name.log"
    _dl_regular "$f" && [[ "$(wc -c < "$f" 2>/dev/null)" -gt 262144 ]] && : > "$f"
    echo "$(date '+%Y-%m-%d %H:%M:%S %z') $name: downloading v$version (process $$)" >&2

    # The wrapper decided to download before the lock was taken; another
    # process may have installed this version since.
    if [[ -x "$binary" ]] && version_at_least "$(read_version_record "$record")" "$version"; then
        return 0
    fi

    for f in "$stage/$name."*.part; do
        [ "$f" = "$part" ] || rm -f "$f"
    done
    _dl_clear_nonregular "$part" || return 42
    # A partial file is made read-only just before it is hashed; one left so
    # by a download stopped before its move is made writable again, or curl
    # could never resume it (exit 23 at every start).
    if _dl_regular "$part" && [[ ! -w "$part" ]]; then
        chmod u+w "$part" 2>/dev/null || rm -f "$part"
    fi

    # The sha256 the result must have, known before anything is downloaded:
    # the pin for this version, or nothing is downloaded.
    download_pin_status "$version" "$pin_version" "$pin"; rc=$?
    case "$rc" in
        30) if [[ -n "$pin" ]]; then f="its pin is for v${pin_version:-no version}"; else f="its pin is empty"; fi
            echo "$name: this plugin has no sha256 for v$version ($f); nothing was downloaded" >&2
            return 30 ;;
        32) echo "$name: the sha256 this plugin pins for v$version is not 64 lowercase hex digits; nothing was downloaded" >&2
            return 32 ;;
    esac
    expected=$pin
    checked_against="the sha256 this plugin pins"

    if _dl_regular "$part" && [[ "$(_dl_sha256 "$part")" == "$expected" ]]; then
        # Complete already: an earlier download finished but was stopped
        # before its move (#67).
        echo "$name: the partial file of v$version is complete and matches; installing it without downloading again" >&2
    else
        # curl and the pause run in the background with wait, so that a TERM
        # stops them at once instead of after they finish. curl's own --retry
        # covers what it calls transient (timeouts, HTTP 408, 429, 5xx); the
        # loop covers the network failing: the host not resolved (6) or not
        # reached (7), a transfer cut short (18), stalled (28), a TLS
        # handshake that failed (35), an empty reply (52), a connection reset
        # while sending or receiving (55, 56), an HTTP/2 stream or framing
        # error (92, 16). Anything else (an HTTP error, a bad certificate, a
        # file that cannot be written) is not retried.
        # -w writes the HTTP status, which -f's exit 22 does not tell, to a
        # file in the staging directory.
        code_file="$stage/$name.http"
        _dl_clear_nonregular "$code_file" || return 42
        for attempt in 1 2 3 4; do
            curl -fsSL -w '%{http_code}\n' --retry 2 --connect-timeout 30 \
                --speed-limit 4096 --speed-time 60 -C - -o "$part" "$url" > "$code_file" &
            DL_CURL=$!
            wait "$DL_CURL"; rc=$?
            DL_CURL=""
            case "$rc" in 6|7|16|18|28|35|52|55|56|92) ;; *) break ;; esac
            [ "$attempt" = 4 ] && break
            echo "$name: the transfer stopped (curl exit status $rc); resuming it (retry $attempt of 3)" >&2
            sleep 2 & DL_CURL=$!; wait "$DL_CURL"; DL_CURL=""
        done
        code=$(head -1 "$code_file" 2>/dev/null)
        rm -f "$code_file"
        case "$rc" in
            0) ;;
            22)
                case "$code" in
                    404|410)
                        rm -f "$part"
                        echo "$name: the server has no v$version asset at $url (HTTP $code); nothing was installed" >&2
                        return 21 ;;
                    *)
                        echo "$name: the server answered HTTP ${code:-with an unknown status} for $url; nothing was installed, the partial file is kept and the next start tries again" >&2
                        return 25 ;;
                esac ;;
            33)
                # The server would not resume: start from zero next time.
                rm -f "$part"
                echo "$name: the download of v$version could not be resumed (curl exit status 33); the next start downloads it again" >&2
                return 20 ;;
            6|7|16|18|28|35|52|55|56|92)
                echo "$name: the download of v$version was interrupted (curl exit status $rc); the next start resumes it" >&2
                return 20 ;;
            *)
                echo "$name: the download of v$version failed (curl exit status $rc); nothing was installed" >&2
                return 24 ;;
        esac
    fi

    # Not writable from here on, still a regular file when it is hashed, and
    # moved into place under the lock it was written under.
    if ! _dl_regular "$part"; then
        rm -f "$part"
        echo "$name: the download is not a regular file; nothing was installed" >&2
        return 42
    fi
    chmod 0555 "$part" || return 40
    f=$(_dl_sha256 "$part")
    if [[ "$f" != "$expected" ]]; then
        rm -f "$part"
        echo "$name: the download of v$version has sha256 ${f:-unknown}, not $expected ($checked_against); it was removed and nothing was installed" >&2
        return 31
    fi
    # Once more, right before the move: the version may have been installed,
    # or a newer one, since this download began, by hand or by a session whose
    # wrapper takes no part in this lock. A binary at least as new is never
    # replaced (PsychQuant/che-msg#83).
    f=$(read_version_record "$record")
    if [[ -x "$binary" ]] && version_at_least "$f" "$version"; then
        rm -f "$part"
        echo "$name: v$f is installed now, not older than v$version; nothing was installed" >&2
        return 0
    fi
    if [[ -d "$binary" && ! -L "$binary" ]]; then
        echo "$name: $binary is a directory; nothing was installed" >&2
        return 40
    fi
    # -h: a link at $binary is replaced, never followed into a directory.
    if ! _dl_regular "$part" || ! mv -f -h "$part" "$binary"; then
        echo "$name: the download could not be moved into place at $binary" >&2
        return 40
    fi
    chmod 0755 "$binary" 2>/dev/null
    tmp="$stage/$name.version.$$"
    if ! ( set -C; printf '%s\n' "$version" > "$tmp" ) 2>/dev/null || ! mv -f -h "$tmp" "$record"; then
        rm -f "$tmp"
        echo "$name: v$version is installed, but its version record $record could not be written" >&2
        return 40
    fi
    echo "$name: installed v$version (sha256 checked against $checked_against)" >&2
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        fetch) shift; download_fetch "$@"; exit $? ;;
        *) echo "usage: download.sh fetch <binary name> <version> <url> <install dir> <pin version> <pin>" >&2; exit 2 ;;
    esac
fi
