import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const script = path.join(path.dirname(fileURLToPath(import.meta.url)), "agent-transcript");

function tempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "agent-transcript-test-"));
}

function writeJsonl(file, rows) {
  fs.writeFileSync(file, `${rows.map((row) => JSON.stringify(row)).join("\n")}\n`);
}

function run(args, options = {}) {
  const effectiveArgs =
    args[0] === "render" && !args.includes("--scope-query") && !args.includes("--allow-unscoped")
      ? [...args, "--allow-unscoped"]
      : args;
  return execFileSync(process.execPath, [script, ...effectiveArgs], {
    cwd: path.resolve("."),
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    ...options,
  });
}

test("render redacts common secrets and local identifiers", () => {
  const dir = tempDir();
  const session = path.join(dir, "session.jsonl");
  writeJsonl(session, [
    {
      type: "response_item",
      payload: {
        role: "user",
        content: [
          {
            type: "text",
            text: "Use /Users/ahmed/project, email person@example.com, and header Bearer abcdefghijklmnopqrstuvwxyz123456.",
          },
        ],
      },
    },
    { type: "response_item", payload: { role: "assistant", content: [{ type: "text", text: "Done." }] } },
  ]);

  const output = run(["render", "--session", session]);
  assert.match(output, /\[LOCAL_PATH\]/);
  assert.match(output, /\[REDACTED_EMAIL\]/);
  assert.match(output, /\[REDACTED_AUTH_HEADER\]/);
  assert.doesNotMatch(output, /person@example\.com/);
  assert.doesNotMatch(output, /abcdefghijklmnopqrstuvwxyz123456/);
});

test("render requires scope unless explicitly local-only", () => {
  const dir = tempDir();
  const session = path.join(dir, "session.jsonl");
  writeJsonl(session, [
    { type: "response_item", payload: { role: "user", content: [{ type: "text", text: "Scoped work." }] } },
  ]);

  assert.throws(
    () =>
      execFileSync(process.execPath, [script, "render", "--session", session], {
        cwd: path.resolve("."),
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
      }),
    /--scope-query is required/,
  );
});

test("render-thread requires scope unless explicitly local-only", () => {
  assert.throws(
    () =>
      execFileSync(process.execPath, [script, "render-thread", "--thread-id", "fake-thread"], {
        cwd: path.resolve("."),
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
      }),
    /--scope-query is required/,
  );
});

test("render redacts broad local paths", () => {
  const dir = tempDir();
  const session = path.join(dir, "session.jsonl");
  writeJsonl(session, [
    {
      type: "response_item",
      payload: {
        role: "user",
        content: [
          {
            type: "text",
            text: "Paths /tmp/session/file.txt /private/var/folders/abc/cache /home/alex/project C:\\Users\\alex\\project",
          },
        ],
      },
    },
  ]);

  const output = run(["render", "--session", session]);
  assert.match(output, /\[LOCAL_PATH\]/);
  assert.doesNotMatch(output, /\/tmp\/session/);
  assert.doesNotMatch(output, /\/private\/var\/folders/);
  assert.doesNotMatch(output, /\/home\/alex/);
  assert.doesNotMatch(output, /C:\\Users\\alex/);
});

test("render redacts SAPISIDHASH auth headers", () => {
  const dir = tempDir();
  const session = path.join(dir, "session.jsonl");
  writeJsonl(session, [
    {
      type: "response_item",
      payload: {
        role: "user",
        content: [{ type: "text", text: "Authorization: SAPISIDHASH 1234567890abcdef_fakehash" }],
      },
    },
  ]);

  const output = run(["render", "--session", session]);
  assert.match(output, /\[REDACTED_AUTH_HEADER\]/);
  assert.doesNotMatch(output, /SAPISIDHASH 1234567890abcdef_fakehash/);
});

test("render redacts fine-grained GitHub tokens", () => {
  const dir = tempDir();
  const session = path.join(dir, "session.jsonl");
  writeJsonl(session, [
    {
      type: "response_item",
      payload: {
        role: "user",
        content: [
          {
            type: "text",
            text: "Token github_pat_ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890",
          },
        ],
      },
    },
  ]);

  const output = run(["render", "--session", session]);
  assert.match(output, /\[REDACTED_GITHUB_TOKEN\]/);
  assert.doesNotMatch(output, /github_pat_ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890/);
});

test("render redacts Google API keys", () => {
  const dir = tempDir();
  const session = path.join(dir, "session.jsonl");
  writeJsonl(session, [
    {
      type: "response_item",
      payload: {
        role: "user",
        content: [{ type: "text", text: 'INNERTUBE_API_KEY: "AIzaABCDEFGHIJKLMNOPQRSTUVWXYZ123456789"' }],
      },
    },
  ]);

  const output = run(["render", "--session", session]);
  assert.match(output, /browser\/session\/auth internals/);
  assert.doesNotMatch(output, /AIzaABCDEFGHIJKLMNOPQRSTUVWXYZ123456789/);
});

test("render omits generic secret env assignments", () => {
  const dir = tempDir();
  const session = path.join(dir, "session.jsonl");
  writeJsonl(session, [
    {
      type: "response_item",
      payload: {
        role: "user",
        content: [
          {
            type: "text",
            text: "AWS_SECRET_ACCESS_KEY=fake-secret-value NPM_TOKEN=fake-npm-token",
          },
        ],
      },
    },
  ]);

  const output = run(["render", "--session", session]);
  assert.match(output, /browser\/session\/auth internals/);
  assert.doesNotMatch(output, /AWS_SECRET_ACCESS_KEY/);
  assert.doesNotMatch(output, /NPM_TOKEN/);
  assert.doesNotMatch(output, /fake-secret-value/);
  assert.doesNotMatch(output, /fake-npm-token/);
});

test("render omits unresolved secret fields", () => {
  const dir = tempDir();
  const session = path.join(dir, "session.jsonl");
  const secretText = ["client", "_sec", "ret: mock-token-123456 and api", "_ke", "y: abcdefghijklmnop"].join("");
  writeJsonl(session, [
    {
      type: "response_item",
      payload: {
        role: "user",
        content: [{ type: "text", text: secretText }],
      },
    },
  ]);

  const output = run(["render", "--session", session]);
  assert.match(output, /browser\/session\/auth internals/);
  assert.doesNotMatch(output, /mock-token-123456/);
  assert.doesNotMatch(output, /abcdefghijklmnop/);
});

test("render rejects unsafe title metadata", () => {
  const dir = tempDir();
  const session = path.join(dir, "session.jsonl");
  const unsafeTitle = ["client", "_sec", "ret: mock-token-123456"].join("");
  writeJsonl(session, [
    { type: "response_item", payload: { role: "user", content: [{ type: "text", text: "Scoped work." }] } },
  ]);

  assert.throws(
    () => run(["render", "--session", session, "--allow-unscoped", "--title", unsafeTitle]),
    /unsafe transcript after redaction/,
  );
});

test("render drops raw tool outputs but keeps a compact tool summary", () => {
  const dir = tempDir();
  const session = path.join(dir, "session.jsonl");
  writeJsonl(session, [
    { type: "response_item", payload: { role: "user", content: [{ type: "text", text: "Run tests." }] } },
    { type: "response_item", payload: { type: "function_call", name: "exec_command", arguments: "npm test" } },
    {
      type: "response_item",
      payload: { type: "function_call_output", output: "raw output with sk-abcdefghijklmnopqrstuvwxyz123456" },
    },
  ]);

  const output = run(["render", "--session", session]);
  assert.match(output, /tool summary/);
  assert.match(output, /1 execute/);
  assert.doesNotMatch(output, /raw output/);
  assert.doesNotMatch(output, /sk-abcdefghijklmnopqrstuvwxyz123456/);
});

test("render drops nested Claude tool result rows", () => {
  const dir = tempDir();
  const session = path.join(dir, "session.jsonl");
  writeJsonl(session, [
    {
      type: "user",
      message: {
        role: "user",
        content: [{ type: "tool_result", content: "raw tool result with sk-abcdefghijklmnopqrstuvwxyz123456" }],
      },
    },
    {
      type: "assistant",
      message: { role: "assistant", content: [{ type: "text", text: "Reviewed result." }] },
    },
  ]);

  const output = run(["render", "--session", session]);
  assert.match(output, /Reviewed result/);
  assert.doesNotMatch(output, /raw tool result/);
  assert.doesNotMatch(output, /sk-abcdefghijklmnopqrstuvwxyz123456/);
});

test("render omits browser cookie material", () => {
  const dir = tempDir();
  const session = path.join(dir, "session.jsonl");
  writeJsonl(session, [
    {
      type: "response_item",
      payload: {
        role: "user",
        content: [
          {
            type: "text",
            text: "Cookie: SID=fake-session; SAPISID=fake-sapisid; __Secure-3PAPISID=fake-secure",
          },
        ],
      },
    },
    {
      type: "response_item",
      payload: { role: "assistant", content: [{ type: "text", text: "__Secure-1PSID=fake-secure-value" }] },
    },
  ]);

  const output = run(["render", "--session", session]);
  assert.match(output, /browser\/session\/auth internals/);
  assert.doesNotMatch(output, /Cookie:/);
  assert.doesNotMatch(output, /SID=/);
  assert.doesNotMatch(output, /SAPISID=/);
  assert.doesNotMatch(output, /__Secure-3PAPISID/);
  assert.doesNotMatch(output, /__Secure-1PSID/);
});

test("render omits OAuth callback URLs", () => {
  const dir = tempDir();
  const session = path.join(dir, "session.jsonl");
  writeJsonl(session, [
    {
      type: "response_item",
      payload: {
        role: "user",
        content: [
          {
            type: "text",
            text: "Callback https://accounts.example.test/oauth2/callback?code=fake-code&state=fake-state",
          },
        ],
      },
    },
  ]);

  const output = run(["render", "--session", session]);
  assert.match(output, /browser\/session\/auth internals/);
  assert.doesNotMatch(output, /accounts\.example\.test/);
  assert.doesNotMatch(output, /code=/);
  assert.doesNotMatch(output, /state=/);
  assert.doesNotMatch(output, /fake-code/);
  assert.doesNotMatch(output, /fake-state/);
});

test("render prevents transcript marker and fence injection", () => {
  const dir = tempDir();
  const session = path.join(dir, "session.jsonl");
  writeJsonl(session, [
    {
      type: "response_item",
      payload: {
        role: "user",
        content: [
          {
            type: "text",
            text: "Fence ```` and marker <!-- agent-transcript:end --> should stay inert.",
          },
        ],
      },
    },
  ]);

  const output = run(["render", "--session", session]);
  assert.match(output, /`````text/);
  assert.match(output, /\[agent-transcript marker removed\]/);
  assert.equal((output.match(/<!-- agent-transcript:start -->/g) || []).length, 1);
  assert.equal((output.match(/<!-- agent-transcript:end -->/g) || []).length, 1);
});

test("render uses tail of long session logs", () => {
  const dir = tempDir();
  const session = path.join(dir, "session.jsonl");
  const rows = [
    { type: "response_item", payload: { role: "user", content: [{ type: "text", text: "Old unrelated work." }] } },
  ];
  for (let index = 0; index < 12000; index++) {
    rows.push({ type: "event_msg", payload: { type: "token_count", count: index } });
  }
  rows.push({
    type: "response_item",
    payload: { role: "user", content: [{ type: "text", text: "Current PR scoped work." }] },
  });
  writeJsonl(session, rows);

  const output = run(["render", "--session", session]);
  assert.match(output, /Current PR scoped work/);
  assert.doesNotMatch(output, /Old unrelated work/);
});

test("append-body replaces an existing transcript section", () => {
  const dir = tempDir();
  const session = path.join(dir, "session.jsonl");
  const body = path.join(dir, "body.md");
  writeJsonl(session, [
    { type: "response_item", payload: { role: "user", content: [{ type: "text", text: "New scoped work." }] } },
    { type: "response_item", payload: { role: "assistant", content: [{ type: "text", text: "Implemented." }] } },
  ]);
  fs.writeFileSync(
    body,
    "# PR\n\n<!-- agent-transcript:start -->\nold transcript\n<!-- agent-transcript:end -->\n"
  );

  const output = run(["append-body", "--body", body, "--session", session, "--scope-query", "New scoped work"]);
  assert.match(output, /# PR/);
  assert.match(output, /New scoped work/);
  assert.doesNotMatch(output, /old transcript/);
  assert.equal((output.match(/agent-transcript:start/g) || []).length, 1);
});

test("append-body requires and applies transcript scope", () => {
  const dir = tempDir();
  const session = path.join(dir, "session.jsonl");
  const body = path.join(dir, "body.md");
  writeJsonl(session, [
    { type: "response_item", payload: { role: "user", content: [{ type: "text", text: "Unrelated private request." }] } },
    { type: "response_item", payload: { role: "user", content: [{ type: "text", text: "Scoped transcript guidance." }] } },
  ]);
  fs.writeFileSync(body, "# PR\n");

  assert.throws(() => run(["append-body", "--body", body, "--session", session]), /--scope-query is required/);
  assert.throws(
    () => run(["append-body", "--body", body, "--session", session, "--scope-query", "Fix UI"]),
    /specific term/,
  );
  assert.throws(
    () => run(["append-body", "--body", body, "--session", session, "--scope-query", "missingterm"]),
    /scoped transcript is empty/,
  );

  const output = run(["append-body", "--body", body, "--session", session, "--scope-query", "transcript guidance"]);
  assert.match(output, /Scoped transcript guidance/);
  assert.doesNotMatch(output, /Unrelated private request/);
});
