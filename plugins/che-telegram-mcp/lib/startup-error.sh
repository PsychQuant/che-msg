#!/bin/bash
# The answer both che-telegram-mcp wrappers give to Claude Code's initialize
# request when they stop before starting their server (#31,
# PsychQuant/che-msg#58, #67). Both wrappers in bin/ source this file; each
# keeps its own fail_startup, because the link to its README section
# (data.docsUrl) has to sit in the wrapper next to its GITHUB_REPO, where the
# layout test checks it.
#
# PR-1b (empirical-driven, 2026-05-22): Claude Code drops a response whose id
# is null as unmatched transport noise, so the error carries the id of the
# initialize request, read briefly from stdin.

# Read first line of stdin (expected: JSON-RPC initialize request) with a
# short timeout, extract the request id. Falls back to "null" if stdin is
# empty, times out, or doesn't contain valid JSON.
#
# Output format mirrors JSON literal: numeric id printed unquoted (e.g.
# `42`), string id wrapped in JSON quotes (e.g. `"abc"`), missing/invalid
# id returns `null`. Caller substitutes this directly into the JSON
# envelope's `"id":<x>` slot.
#
# Timeout is 2s — Claude Code MCP transport typically sends initialize
# within milliseconds of spawning the child process. Longer timeout
# would delay wrapper exit and could push Claude Code into its own
# transport timeout.
read_initialize_id() {
    local line=""
    local id="null"

    if IFS= read -r -t 2 line 2>/dev/null && [ -n "$line" ]; then
        if command -v jq >/dev/null 2>&1; then
            # jq -c outputs JSON-compact form: number unquoted, string with
            # quotes, null as literal `null`. Perfect for direct substitution.
            local extracted
            extracted=$(printf '%s' "$line" | jq -c '.id' 2>/dev/null || true)
            if [ -n "$extracted" ]; then
                id="$extracted"
            fi
        else
            # Fallback for environments without jq. Handles integer ids
            # and quoted string ids — covers MCP 1.0 spec (id is string,
            # number, or null per JSON-RPC 2.0).
            if [[ "$line" =~ \"id\"[[:space:]]*:[[:space:]]*([0-9]+) ]]; then
                id="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ \"id\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
                id="\"${BASH_REMATCH[1]}\""
            fi
        fi
    fi

    printf '%s' "$id"
}
