#!/bin/bash
# A stand-in for curl in the che-telegram-mcp wrapper tests
# (PsychQuant/che-msg#56). It never reaches the network.
#
# Every call appends its arguments, on one line, to $HOME/curl.calls, and its
# PID to $HOME/curl.pids. What it answers is set by files the test writes in
# $HOME/fake-curl/, one set per route: "api" for an api.github.com URL,
# "asset" for a /releases/download/ URL.
#
#   <route>          the body to serve (to the -o file, or stdout)
#   <route>.status   an HTTP error status (for example 404): with -f the call
#                    exits 22 and writes nothing; without -f it writes the
#                    error page and exits 0, as `curl -sL` does
#   <route>.cuts     one byte offset per call of that route: call k stops once
#                    the body has been served up to that offset and exits 56
#                    (connection reset); a line "full", or no line, serves the
#                    rest
#   <route>.delay    whole seconds to wait before serving
#   <route>.exit     an exit status to fail with, writing nothing (for
#                    example 7, could not connect, or 60, a bad certificate)
#
# With -C - and an existing -o file it serves the body from that file's size
# on, appended. An -o file it cannot write makes it exit 23, as curl does. At or past the end it writes nothing and exits 0, as curl does
# when a server answers 416 to a resumed request.
#
# With -w containing %{http_code} it prints that call's HTTP status (200, the
# <route>.status, 416 for a resume at the end, 000 when nothing was served) on
# stdout when it ends, after the body when there is no -o.
#
# A route without a body file, and any other URL, exits 1 with no output, so
# by default every call fails, as the harness's curl did before #56.

echo "$*" >> "$HOME/curl.calls"
echo $$ >> "$HOME/curl.pids"

out="" url="" fail=no resume=no wfmt=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o|--output) out=${2:-}; shift ;;
        -w|--write-out) wfmt=${2:-}; shift ;;
        -C|--continue-at) [ "${2:-}" = - ] && resume=yes; shift ;;
        --fail|--fail-with-body) fail=yes ;;
        --*) ;;
        -*) case "$1" in *f*) fail=yes ;; esac ;;
        http://*|https://*) url=$1 ;;
    esac
    shift
done

# finish <exit status> <http code>: prints the -w output, then exits.
finish() {
    case "$wfmt" in *'%{http_code}'*) printf '%s\n' "$2" ;; esac
    exit "$1"
}

case "$url" in
    https://api.github.com/*) route=api ;;
    */releases/download/*)    route=asset ;;
    *)                        finish 1 000 ;;
esac
conf="$HOME/fake-curl"
body="$conf/$route"
[ -f "$body" ] || finish 1 000

# The k-th call of this route (1-based).
count_file="$conf/$route.count"
calls=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
echo "$calls" > "$count_file"

if [ -f "$conf/$route.delay" ]; then
    tenths=$(( $(cat "$conf/$route.delay") * 10 ))
    while [ "$tenths" -gt 0 ]; do sleep 0.1; tenths=$((tenths - 1)); done
fi

# write <bytes source command...>: to the -o file (appended when resuming) or stdout.
write() {
    if [ -n "$out" ] && [ -e "$out" ] && [ ! -w "$out" ]; then exit 23; fi
    if [ -z "$out" ]; then "$@"
    elif [ "$resume" = yes ]; then "$@" >> "$out"
    else "$@" > "$out"; fi
}

if [ -f "$conf/$route.exit" ]; then
    finish "$(cat "$conf/$route.exit")" 000
fi

if [ -f "$conf/$route.status" ]; then
    status=$(cat "$conf/$route.status")
    [ "$fail" = yes ] && finish 22 "$status"
    write printf 'Not Found'
    finish 0 "$status"
fi

size=$(wc -c < "$body" | tr -d ' ')
offset=0
if [ "$resume" = yes ] && [ -n "$out" ] && [ -f "$out" ]; then
    offset=$(wc -c < "$out" | tr -d ' ')
fi
[ "$offset" -ge "$size" ] && finish 0 416

end=$size cut=no
limit=$(sed -n "${calls}p" "$conf/$route.cuts" 2>/dev/null)
case "$limit" in
    ''|full) ;;
    *) if [ "$limit" -lt "$size" ]; then end=$limit; cut=yes; fi ;;
esac
slice() { tail -c +"$((offset + 1))" "$body" | head -c "$((end - offset))"; }
[ "$end" -gt "$offset" ] && write slice
[ "$cut" = yes ] && finish 56 200
finish 0 200
