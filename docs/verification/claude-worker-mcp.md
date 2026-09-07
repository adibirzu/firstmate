# Claude worker MCP verification

The MCP-only print-mode probe passed on 2026-09-06 on macOS with Claude Code 2.1.257.
[Configuration](../configuration.md#claude-worker-mcp-isolation) owns the operator contract.

## Credentialed launch guard

Run:

```sh
FM_CLAUDE_MCP_LIVE=1 bash tests/fm-claude-mcp-live-e2e.test.sh
```

The initial MCP-only print-mode probe used the actual command emitted by `fm-spawn.sh` with the installed Claude binary and existing credentials in bounded print mode.
The interactive PTY guard has not passed a live run yet because its prior attempt stalled at the workspace-trust screen and cleanup timed out after SIGKILL.
The status-line and per-event automation guarantee awaits a successful interactive guard result.
The guard now uses an interactive PTY to exercise status-line behavior too, while pane allocation remains simulated.
It checks Read and Bash, owned completion hooks, primary settings checksum, and descendant process samples captured externally with `ps -axo pid=,ppid=,args=`.
The launch includes `--strict-mcp-config --mcp-config '{"mcpServers":{}}' --settings '<per-launch plugin overrides>' --setting-sources project,local --no-chrome`.
The settings override explicitly maps configured plugin identifiers to false, rather than relying on an empty object to replace merged settings.
No credential directory is created or copied.
An additional process snapshot during the initial print-mode probe showed zero worker MCP descendants while 56 unrelated MCP processes remained present.
This establishes the MCP-only worker boundary without terminating primary or other worker processes.
Organization-managed policy and other Claude versions require their own credentialed verification.

## Portable checks

Run:

```sh
bash tests/fm-claude-worker-config.test.sh
bash tests/fm-spawn-dispatch-profile.test.sh
```

The configuration regression output is:

```text
ok - all user, project and local plugins disabled without changing primary
ok - default MCP empty and explicit opt-in contains only approved server
ok - invalid configuration fails closed
```

The dispatch regression exercises the public spawn command with isolated Git fixtures and a recording pane transport.
It pins empty defaults, strict opt-in, and secondmate isolation alongside existing profile and credential-store forwarding checks.
The live guard belongs to the `live-harness-optin` test family and skips unless explicitly enabled.

The complete dispatch suite ended with:

```text
# all fm-spawn-dispatch-profile tests passed
```

Additional validation commands:

```sh
bin/fm-lint.sh
shellcheck -x bin/fm-claude-worker-config.sh tests/fm-claude-worker-config.test.sh tests/fm-claude-mcp-live-e2e.test.sh
bin/fm-doc-audience-check.sh
bin/fm-test-run.sh --check-coverage
```

ShellCheck exited zero without diagnostics.
The documentation and test coverage checks reported:

```text
fm-doc-audience-check: ok surfaces=122 local_links=337
FM_TEST_COVERAGE ok total=205 parallel=24 serial=170 serial_shards=4 herdr=11
```


## User-profile automation isolation

The default launch excludes the user settings source, removing the primary profile's status-line command and per-event hooks without blanket hook disablement.
Project and local hooks remain enabled.
The dispatch regression verifies the `--claude-user-settings` opt-in and the default on secondmate launches.
The interactive guard rejects any observed descendant or debug entry naming `LIFEOS_StatusLine.sh` or the primary `.claude/hooks/` directory.
Its owned Stop marker and Bash proof artifact verify that task supervision remains functional.
