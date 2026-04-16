# Privacy Policy

## Data Collection

This MCP server:
- Runs entirely locally on your Mac
- Does not collect or transmit any personal data to third parties
- Communicates only with Telegram servers via TDLib (MTProto protocol)
- Stores a TDLib session database locally for persistent authentication

## Credentials

- Telegram API credentials (api_id, api_hash) are provided during authentication
- Your phone number and verification code are sent to Telegram servers only
- Session data is stored in `~/Library/Application Support/che-telegram-all-mcp/tdlib/`

## Local Storage

TDLib maintains a local database containing:
- Chat list and metadata
- Message cache
- Authentication session

This data is stored solely on your Mac and is never transmitted to third parties.

## Third-Party Services

This extension communicates with:
- **Telegram servers** (via TDLib/MTProto) - to execute Telegram operations

## Contact

For questions about this privacy policy, please open an issue at:
https://github.com/PsychQuant/che-msg/issues
