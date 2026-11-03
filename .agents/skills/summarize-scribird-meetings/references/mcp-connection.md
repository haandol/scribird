# Recover the maintained MCP connection

Use this only when Scribird tools are absent, fail to start, or lack the fields
needed by the summary workflow. A configured server marked enabled is not proof
that its command works.

For Codex, inspect the `scribird` MCP entry with the supported `codex mcp get`
command. Inspect the command and argument paths, not unrelated credentials or the
entire environment. The documented server command is:

```text
uv run --directory /absolute/path/to/scribird/mcp --frozen python server.py
```

The checkout must contain `mcp/pyproject.toml`, `mcp/uv.lock` and `mcp/server.py`.
The application bundle alone does not include this Python adapter. In an authorized
setup/repair task, restore the user's known checkout or correct the configuration
to a verified existing checkout, then run `uv sync --project <checkout>/mcp --frozen`.
Do not clone an unrelated repository, replace the app or change recording settings.

Reconnect the MCP server in the client after restoring its files or changing its
command. A running agent session may need a new turn or session before the client
advertises the tools. If the active client cannot refresh its tool list, the existing
MCP Inspector CLI can call `list_sessions` and `read_session` through the verified
configured command. This uses the same archive tools and allows the summary to
continue. Use the CLI's current help for its arguments; do not implement another
stdio client. Use these read-only tools for connection checks, not recording controls.

The archive tools work while the app is closed. When diagnosing an app-root lookup
failure, a user-specified `output_root` can still permit archive reads; retain the
actual scanned root in the answer. Do not start the app solely to read saved text.

The public tool contract is maintained in the checkout's `mcp/README.md`.
If the checked-out server is older and lacks `recording_date`, `nextOffset`,
`citationLabels` or `transcriptSummary`, report that version mismatch and update the
maintained server when authorized. Do not turn missing fields into guessed metadata
or introduce a request-specific parser. Independent summary work may continue from
transcript content already available, with its actual coverage stated.
