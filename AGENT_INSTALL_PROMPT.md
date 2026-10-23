## Install with an AI agent

Paste this into an AI coding agent such as Claude Code. Moose detects and installs its own prerequisites on first launch, so the agent does not have to:

```text
Install Moose on this Mac.
1. Run: curl -fsSL https://raw.githubusercontent.com/kalahroudi/moose/main/scripts/install.sh | bash
2. Moose opens its first-run guide. Moose is open source and ships no shared Google keys, so I create my own
   Google sign-in client once: the guide opens the exact Google Cloud pages and imports the downloaded
   client_secret_*.json by itself. Tell me which page to click through and wait until the guide shows my
   Gmail account as connected. If a step needs my password, tell me the exact command to run in Terminal.
3. Register its MCP server: claude mcp add moose --scope user -- /Applications/Moose.app/Contents/MacOS/moose-mcp
4. Call get_status and tell me what it reports.
Never call a destructive tool without asking me first.
```
