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
# message) with a short timeout and sets REQUEST_ID to its id as a JSON
# literal, for the caller to put in the envelope's `"id":<x>` slot: a number
# unquoted (e.g. `42`), a string in JSON quotes (e.g. `"abc"`), `null` if
# stdin is empty, times out, has no id, or is not JSON.
#
# When the message is a request for another method than initialize, it
# writes the -32601 answer to stdout and exits 1 instead; a notification for
# another method gets no answer (JSON-RPC answers no notification). So call
# it directly, never inside $(...). A message whose method is initialize,
# missing or not a string is left to the caller's startup error.
#
# Timeout is 2s — Claude Code MCP transport typically sends its first
# request within milliseconds of spawning the child process. Longer timeout
# would delay wrapper exit and could push Claude Code into its own
# transport timeout.
read_first_request() {
    local line="" method=""
    REQUEST_ID=null

    if IFS= read -r -t 2 line 2>/dev/null && [ -n "$line" ]; then
        if command -v jq >/dev/null 2>&1; then
            # jq -c outputs JSON-compact form: number unquoted, string with
            # quotes, null as literal `null`. Perfect for direct substitution.
            local extracted
            extracted=$(printf '%s' "$line" | jq -c '.id' 2>/dev/null || true)
            if [ -n "$extracted" ]; then
                REQUEST_ID="$extracted"
            fi
            method=$(printf '%s' "$line" | jq -r '.method | strings' 2>/dev/null || true)
        else
            # Fallback for environments without jq. Handles integer ids
            # and quoted string ids — covers MCP 1.0 spec (id is string,
            # number, or null per JSON-RPC 2.0) — and a quoted method. The
            # first match on the line is taken.
            if [[ "$line" =~ \"id\"[[:space:]]*:[[:space:]]*([0-9]+) ]]; then
                REQUEST_ID="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ \"id\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
                REQUEST_ID="\"${BASH_REMATCH[1]}\""
            fi
            if [[ "$line" =~ \"method\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
                method="${BASH_REMATCH[1]}"
            fi
        fi
    fi

    if [[ -n "$method" && "$method" != initialize ]]; then
        if [[ "$REQUEST_ID" != null ]]; then
            printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"Method not found"}}\n' "$REQUEST_ID"
        fi
        exit 1
    fi
}
