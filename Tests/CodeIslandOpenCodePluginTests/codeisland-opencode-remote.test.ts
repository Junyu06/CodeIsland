import { afterAll, describe, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";

// The remote plugin hands every event to ~/.codeisland/codeisland-remote-hook.py
// on the SSH host. A stand-in hook in a temp HOME records what it would forward.
const home = mkdtempSync(join(tmpdir(), "codeisland-remote-plugin-"));
const received = join(home, "received.jsonl");
mkdirSync(join(home, ".codeisland"));
const hook = join(home, ".codeisland", "codeisland-remote-hook.py");
writeFileSync(hook, [
  "import sys",
  `with open(${JSON.stringify(received)}, "a") as out:`,
  "    out.write(sys.stdin.read() + \"\\n\")",
  "",
].join("\n"));
chmodSync(hook, 0o755);

const savedHome = process.env.HOME;
process.env.HOME = home;
const { default: plugin } = await import("../../Sources/CodeIsland/Resources/codeisland-opencode-remote.js");
process.env.HOME = savedHome;

afterAll(() => rmSync(home, { recursive: true, force: true }));

const forwarded = async (count: number) => {
  for (let i = 0; i < 200; i++) {
    if (existsSync(received)) {
      const lines = readFileSync(received, "utf8").trim().split("\n").filter(Boolean);
      if (lines.length >= count) return lines.map((line) => JSON.parse(line));
    }
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error("the remote hook was not called");
};

describe("remote OpenCode plugin", () => {
  test("the generated title rides Stop as session_title, the key the island reads", async () => {
    const hooks = await plugin.server({ client: undefined, serverUrl: undefined });
    await hooks.event({ event: { type: "session.updated", properties: { info: { id: "s1", title: "Child session - 2026-10-09" } } } });
    await hooks.event({ event: { type: "session.status", properties: { sessionID: "s1", status: { type: "idle" } } } });
    await hooks.event({ event: { type: "session.updated", properties: { info: { id: "s1", title: "Fix the login form" } } } });
    await hooks.event({ event: { type: "session.status", properties: { sessionID: "s1", status: { type: "idle" } } } });

    const [placeholderStop, titledStop] = await forwarded(2);
    expect(placeholderStop.hook_event_name).toBe("Stop");
    expect(placeholderStop.session_title).toBeUndefined();
    expect(titledStop.hook_event_name).toBe("Stop");
    expect(titledStop.session_id).toBe("opencode-s1");
    expect(titledStop.session_title).toBe("Fix the login form");
    expect(titledStop.codex_title).toBeUndefined();
  });

  // The remote hook sends facts and the island keeps a cwd it is given, so
  // an unknown one is never "": it is the directory OpenCode runs in, which
  // the remote hook used to put in its place.
  test("a session with no known cwd reports the directory OpenCode runs in", async () => {
    const savedPwd = process.env.PWD;
    delete process.env.PWD;
    try {
      const hooks = await plugin.server({ client: undefined, serverUrl: undefined });
      await hooks.event({ event: { type: "session.created", properties: { info: { id: "s2" } } } });
      await hooks.event({ event: { type: "session.next.compaction.started", properties: { sessionID: "s2" } } });
      const events = await forwarded(4);
      const [start, compact] = events.slice(-2);
      expect(start.hook_event_name).toBe("SessionStart");
      expect(start.cwd).toBe(process.cwd());
      expect(compact.hook_event_name).toBe("PreCompact");
      expect(compact.session_id).toBe("opencode-s2");
      expect(compact.cwd).toBe(process.cwd());
      expect(compact._source).toBeUndefined();
      expect(compact._remote_host_id).toBeUndefined();
      // A pid of the remote host is not one the island can track.
      expect(compact._ppid).toBeUndefined();
    } finally {
      process.env.PWD = savedPwd;
    }
  });
});
