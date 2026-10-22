# Hook edge protocol

An *edge* is whatever sits between an AI coding agent's hook and the island:
`codeisland-bridge` on the Mac, the Python remote hook on SSH hosts, the
plugins (OpenCode, pi, Oh My Pi, OpenClaw), the community Windows bridge.

What a hook *means* — which agent sent it, which session, whether the agent
waits for an answer and in what form — is decided in one place:
`HookIntake` (`Sources/CodeIslandCore/HookIntake.swift`). The bridge runs it
itself. An edge that cannot run Swift sends the **facts** it observed instead,
and the island runs HookIntake on them when the payload arrives. A provider
quirk is then fixed once, in HookIntake, for every edge.

## Transport

- One Unix-domain stream connection per hook invocation, to
  `$CODEISLAND_SOCKET_PATH`, else `/tmp/codeisland-<uid>.sock` (on a remote
  host, the path the installer forwarded).
- Write one JSON object, then half-close the write side (`shutdown(SHUT_WR)`).
- Read the answer to EOF only when the hook waits for one (below). Print it to
  stdout exactly as received; an empty answer means print nothing.
- If the island is not running, exit 0 silently.

## Payload

The agent's stdin object, unchanged, at the top level — plus `_edge`:

```json
{
  "hook_event_name": "PermissionRequest",
  "session_id": "c1a0de00-…",
  "tool_name": "Bash",
  "tool_input": { "command": "make" },
  "_edge": {
    "v": 1,
    "source": "claude",
    "cwd": "/home/dev/project",
    "tty": "/dev/pts/3",
    "host": { "id": "devbox", "name": "Dev Box" },
    "stdin_sha256": "9f2c…",
    "waits": true
  }
}
```

An edge may add what only it can read, under the keys the island already
knows (the remote hook adds transcript fields such as `last_assistant_message`
and `_hermes_store`). It does not add `_source`, `_ppid`, `_tty`, `_term_*`,
`_remote_host_*` or other derived `_` fields: those are HookIntake's.

### `_edge` fields

| Field | Type | Meaning |
|---|---|---|
| `v` | int | Facts version, `1`. Fields are added without changing it. |
| `source` | string | The agent the hook was installed for (the bridge's `--source`). `claude` means Claude Code's own `settings.json` hook — which Cursor and other agents also run — so the payload decides, with Claude as the default. |
| `event` | string | The bridge's `--event`, for agents whose stdin names no event. |
| `cwd` | string | The hook process's working directory. Used when the payload has no `cwd`. |
| `tty` | string | The controlling terminal, if any. |
| `stdin_sha256` | hex string | SHA-256 of the stdin bytes exactly as the agent wrote them. Cursor runs two hooks per step with one stdin; the digest lets the island keep one (#377). |
| `waits` | bool | Whether this edge waits for the answer (see below). The island never holds a hook nobody waits on. |
| `host` | `{id, name}` | Present when the edge runs on another machine. Its processes, files and home are not the Mac's: no pid is tracked, nothing is looked up locally. |
| `env` | object | Only the variables in `HookIntake.environmentKeys` (terminal and multiplexer ids, `GROK_*`, `HERMES_HOME`, `CODEISLAND_SKIP`). Never anything else. Terminal ids of another machine are no use on the Mac: the remote hook sends none. |
| `ppid` | int | The hook's parent process id. Local edges only. |
| `tmux_client_tty` | string | `tmux display-message -p -t $TMUX_PANE '#{client_tty}'`, if the edge ran it. |

Never send the argv of ancestor processes or more environment than listed.

## Waiting for the answer

Decide locally, from the stdin, so that no other hook pays a round trip, and
send the decision as `waits`. Wait if the event name (`hook_event_name`, else
`event`) is one of `PermissionRequest`, `permission_request`, `BeforeTool`; or
one of `Notification`, `notification`, `afterAgentThought`, `errorOccurred`
**and** `question` is a string. Otherwise send and close.

The island has the last word: a hook HookIntake does not hold — one Cursor
runs, whose stdout Cursor reads against its own schema — is answered at once
with nothing, and its edge prints nothing; a hook its edge does not wait on
(`waits: false`, whatever its event is spelled) gets no card. The answer it
does send is already in the form the agent reads (Gemini CLI and Google
Antigravity get `{"decision":"allow"|"deny"}`), so print it verbatim.

One answer cannot wait for the island: Google Antigravity refuses a tool call
whose `PreToolUse` hook prints nothing, so an edge serving it prints
`{"decision":"ask"}` first, before anything can make it exit
(`HookIntake.immediateStdout`, #339).

## What the island derives

From the facts and the stdin, in this order (HookIntake is normative):

1. Dropped: `CODEISLAND_SKIP` set; inside Grok (`GROK_SESSION_ID` /
   `GROK_HOOK_EVENT`), any hook but Grok's own.
2. A non-blank `cursor_version` marks a hook Cursor ran: source `cursor`
   (or `cursor-cli` under cursor-agent) unless a source is declared, never
   held for an answer, `stdin_sha256` kept as the delivery digest.
3. Aliases: `hookEventName` / `eventName` / `event` / `--event` →
   `hook_event_name`; `sessionId`, `payload.session_id`, `data.session_id`,
   `conversationId` → `session_id`; `transcriptPath` → `transcript_path`.
   Copilot and Cline payload shapes are mapped by source.
4. Source: the declared one, else a supported `_source` in the payload, else
   Cursor's payload, else (bridge only) the process ancestry, else the
   default. A hook the ancestry attributes to an agent other than Claude
   Code is another agent firing Claude Code's hook, marked `_via_plugin`.
5. On the Mac only: `_ppid` (the long-lived agent process), and a
   `<source>-ppid-<pid>` session id when the agent sends none. A hook still
   without a session id is dropped.
6. Terminal context from `env`, `tty`, `cwd`; `_remote_host_id` /
   `_remote_host_name` from `host` unless the payload names its host.

## Compatibility

- A payload without `_edge` is its edge's own interpretation and is taken as
  it is: hooks installed before this protocol keep working unchanged.
- An island reads another `v` for the fields it knows.
- Do not pipe facts through `codeisland-bridge`: it observes its own and
  drops an `_edge` it finds in its stdin.

## For the Windows bridge

The Windows port runs its own island, so it cannot hand facts to HookIntake.
It should follow the same rules — in particular rule 2 (Cursor runs Claude
Code's hooks; without it, Cursor's events show as Claude and every step that
both configs wire arrives twice) and the waiting rule above. The golden
fixtures in `Tests/CodeIslandCoreTests/BridgeGoldenFixtures.swift`, with the
output recorded in `BridgeGoldenExpectations.swift`, are worked examples for
every agent the bridge serves.
