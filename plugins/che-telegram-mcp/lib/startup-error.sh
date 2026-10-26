#!/bin/bash
# The answer both che-telegram-mcp wrappers give to Claude Code's first
# request when they stop before starting their server (#31,
# PsychQuant/che-msg#58, #59, #67). Both wrappers in bin/ source this file;
# each keeps its own fail_startup, because the link to its README section
# (data.docsUrl) has to sit in the wrapper next to its GITHUB_REPO, where the
# layout test checks it.
#
# PR-1b (empirical-driven, 2026-05-22): Claude Code drops a response whose id
# is null as unmatched transport noise, so the error carries the id of the
# initialize request, read briefly from stdin.
#
# The startup error answers only initialize. Claude Code builds from 2026-10
# may send a server/discover request first (PsychQuant/che-msg#59); a first
# request for any method other than initialize is answered here with
# "method not found" (-32601) for its own id, and the wrapper exits 1 as it
# does after the startup error.

# read_first_request: reads the first line of stdin (the client's first
# message) with a 2 s timeout and either answers it here and exits 1, or sets
# REQUEST_ID, the id the caller's startup error (-32000) answers, as a JSON
# literal for the envelope's `"id":<x>` slot. Call it directly, never inside
# $(...). The line is judged with jq as one JSON value; an object's id counts
# only when it is a string, a number or null. Only these kinds of line, and
# no other:
#
#   initialize with an id member          REQUEST_ID = that id
#   another non-empty string method,
#     with an id member (null included)   -32601 for that id, exit 1
#   a string method, initialize included,
#     and no id member (a notification)   no answer, exit 1
#   a JSON array (a batch; MCP has none)  -32600 with id null, exit 1
#   an object whose method is missing,
#     not a string or empty               REQUEST_ID = its id, or null
#   anything else: no complete line
#     within 2 s (input that ends without
#     a newline counts as none), an empty
#     line, not exactly one JSON value, a
#     value that is neither an object nor
#     an array, an id of another type, or
#     no jq 1.7 or later (startup_jq)     REQUEST_ID = null
#
# There is no parser without jq: macOS ships /usr/bin/jq, and a hand-written
# one read nested fields and mangled ids that were not plain integers or
# strings (PsychQuant/che-msg#59).
#
# Timeout is 2s — Claude Code MCP transport typically sends its first
# request within milliseconds of spawning the child process. Longer timeout
# would delay wrapper exit and could push Claude Code into its own
# transport timeout.
read_first_request() {
    local line="" verdict="" kind id jq
    REQUEST_ID=null

    IFS= read -r -t 2 line 2>/dev/null || return 0
    [ -n "$line" ] || return 0
    jq=$(startup_jq) || return 0

    # One line, "<kind> <id as JSON>"; tojson keeps an id on one line, and
    # jq 1.7 or later writes an unchanged number literal as it was written.
    verdict=$(printf '%s\n' "$line" | "$jq" -r -s '
        if length != 1 then "unparseable"
        else .[0]
        | if type == "array" then "batch"
          elif type != "object" then "unparseable"
          elif has("id") and ((.id | type) as $t
                 | ($t != "string" and $t != "number" and $t != "null")) then "unparseable"
          else
            (if has("id") then (.id | tojson) else "" end) as $id
            | (if (.method | type) == "string" then .method else "" end) as $method
            | if $method == "" then "startup \(if $id == "" then "null" else $id end)"
              elif $id == "" then "notification"
              elif $method == "initialize" then "startup \($id)"
              else "other \($id)"
              end
          end
        end' 2>/dev/null) || return 0

    kind=${verdict%% *}
    id=${verdict#* }
    case "$kind" in
        startup)
            REQUEST_ID=$id ;;
        other)
            printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"Method not found"}}\n' "$id"
            exit 1 ;;
        notification)
            exit 1 ;;
        batch)
            printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Invalid Request"}}\n'
            exit 1 ;;
    esac
}

# The jq tried first: the one macOS includes. A test may set it to another
# path after sourcing this file.
STARTUP_SYSTEM_JQ=/usr/bin/jq

# startup_jq: prints the path of the first jq of version 1.7 or later among
# $STARTUP_SYSTEM_JQ and the jq on PATH, by what `jq --version` reports
# (jq-1.7.1, jq-1.7.1-apple, jq-1.8.2 ...); returns 1 when there is none. An
# older jq rounds a number literal it writes back (jq 1.6 turns
# 9007199254740993 into 9007199254740992), so an id echoed through it could
# differ from the request's (PsychQuant/che-msg#59).
startup_jq() {
    local candidate version
    for candidate in "$STARTUP_SYSTEM_JQ" "$(command -v jq 2>/dev/null)"; do
        [ -n "$candidate" ] && [ -x "$candidate" ] || continue
        version=$("$candidate" --version 2>/dev/null)
        [[ "$version" =~ ^jq-([0-9]+)\.([0-9]+) ]] || continue
        if (( 10#${BASH_REMATCH[1]} > 1 || (10#${BASH_REMATCH[1]} == 1 && 10#${BASH_REMATCH[2]} >= 7) )); then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}
