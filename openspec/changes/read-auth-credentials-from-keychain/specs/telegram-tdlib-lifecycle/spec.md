## MODIFIED Requirements

### Requirement: TDLib opens on first use, not at startup

The server SHALL NOT create a TDLib client or acquire the TDLib lock during startup. The server SHALL open TDLib only when a tool that needs TDLib is called and the TDLib lock is free. After opening TDLib, the server SHALL wait, for at most 30 seconds, until authorization has gone as far as it can without a caller before it answers the call: TDLib is ready or closed, an automatic step (setting parameters from the environment, or sending the phone number or the 2FA password from the environment or the Keychain) failed, or TDLib waits for input that neither the environment nor the Keychain provides. A Keychain lookup that is still running, or a value it found that has not been sent yet, SHALL count as not settled.

#### Scenario: Server starts without holding TDLib

- **WHEN** the `che-telegram-all-mcp` server starts and no tool has been called
- **THEN** the lock file `~/.cache/che-telegram-all-mcp.tdlib.lock` is not locked by the server process and no TDLib client exists in that process

#### Scenario: First tool call with a free lock opens TDLib

- **WHEN** `get_chats` is called and no other process holds the TDLib lock
- **THEN** the server acquires the lock, writes its PID to `~/.cache/che-telegram-all-mcp.tdlib.owner`, opens TDLib, and returns the result produced by TDLib

#### Scenario: First call on a logged-in account is answered after login

- **WHEN** `get_chats` is the first call after the server opened TDLib for an account that is logged in, and the API credentials are in the environment
- **THEN** the result is the chat list produced by TDLib, not a "Not authenticated" error

#### Scenario: First call waits for the 2FA password from the Keychain

- **WHEN** `get_chats` is the first call, TDLib reaches `waitingForPassword`, the environment has no `TELEGRAM_2FA_PASSWORD`, and the Keychain item lookup has not returned yet
- **THEN** the server keeps waiting (within the 30-second limit) instead of answering "Not authenticated", and answers after the stored password has been sent and TDLib has moved on
