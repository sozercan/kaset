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

test("render omits credential-bearing service URLs", () => {
  const dir = tempDir();
  const session = path.join(dir, "session.jsonl");
  writeJsonl(session, [
    {
      type: "response_item",
      payload: {
        role: "user",
        content: [{ type: "text", text: "DATABASE_URL=postgres://user:pass@example.test/db" }],
      },
    },
  ]);

  const output = run(["render", "--session", session]);
  assert.match(output, /browser\/session\/auth internals/);
  assert.doesNotMatch(output, /postgres:\/\//);
  assert.doesNotMatch(output, /example\.test/);
});

test("render omits credential URLs with email-style usernames", () => {
  const dir = tempDir();
  const session = path.join(dir, "session.jsonl");
  writeJsonl(session, [
    {
      type: "response_item",
      payload: {
        role: "user",
        content: [{ type: "text", text: "DATABASE_URL=postgres://user@example.com:mock-password@db.example.test/app" }],
      },
    },
  ]);

  const output = run(["render", "--session", session]);
  assert.match(output, /browser\/session\/auth internals/);
  assert.doesNotMatch(output, /mock-password/);
  assert.doesNotMatch(output, /db\.example\.test/);
});

test("render keeps AGENTS.md task prompts when scoped", () => {
  const dir = tempDir();
  const session = path.join(dir, "session.jsonl");
  writeJsonl(session, [
    {
      type: "response_item",
      payload: {
        role: "user",
        content: [{ type: "text", text: "Please update AGENTS.md with review guidance." }],
      },
    },
  ]);

  const output = run(["render", "--session", session, "--scope-query", "AGENTS.md review guidance"]);
  assert.match(output, /Please update AGENTS\.md with review guidance/);
});

test("render omits AGENTS.md setup blobs when scoped", () => {
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
            text: "# AGENTS.md instructions for /repo\n\nGuidance for AI coding assistants working on this repository.\n\nReview guidance.",
          },
        ],
      },
    },
  ]);

  assert.throws(
    () => run(["render", "--session", session, "--scope-query", "AGENTS.md review guidance"]),
    /scoped transcript is empty/,
  );
});

test("render omits explicit setup instruction blobs when scoped", () => {
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
            text: "Here are your instructions:\n\nScoped transcript guidance.",
          },
        ],
      },
    },
  ]);

  assert.throws(
    () => run(["render", "--session", session, "--scope-query", "transcript guidance"]),
    /scoped transcript is empty/,
  );
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

test("render omits quoted secret env assignments with spaces", () => {
  const dir = tempDir();
  const session = path.join(dir, "session.jsonl");
  writeJsonl(session, [
    {
      type: "response_item",
      payload: {
        role: "user",
        content: [{ type: "text", text: 'PASSWORD="mock secret phrase value"' }],
      },
    },
  ]);

  const output = run(["render", "--session", session]);
  assert.match(output, /browser\/session\/auth internals/);
  assert.doesNotMatch(output, /mock secret phrase value/);
  assert.doesNotMatch(output, /phrase value/);
});

test("render omits colon-style quoted secret fields with spaces", () => {
  const dir = tempDir();
  const session = path.join(dir, "session.jsonl");
  writeJsonl(session, [
    {
      type: "response_item",
      payload: {
        role: "user",
        content: [{ type: "text", text: 'password: "mock secret phrase value"\n{"api_key": "mock api key value"}' }],
      },
    },
  ]);

  const output = run(["render", "--session", session]);
  assert.match(output, /browser\/session\/auth internals/);
  assert.doesNotMatch(output, /mock secret phrase value/);
  assert.doesNotMatch(output, /mock api key value/);
  assert.doesNotMatch(output, /phrase value/);
});

test("render omits slash-prefixed secret env assignments", () => {
  const dir = tempDir();
  const session = path.join(dir, "session.jsonl");
  writeJsonl(session, [
    {
      type: "response_item",
      payload: {
        role: "user",
        content: [{ type: "text", text: "API_TOKEN=/abcDEF123456 PASSWORD=/secret-value" }],
      },
    },
  ]);

  const output = run(["render", "--session", session]);
  assert.match(output, /browser\/session\/auth internals/);
  assert.doesNotMatch(output, /abcDEF123456/);
  assert.doesNotMatch(output, /secret-value/);
});

test("render omits declared secret literals", () => {
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
            text: 'const DATABASE_PASSWORD = "supersecret123"; let API_TOKEN = "mock-token-123456"; const SECRET = "/slash-secret-123456";',
          },
        ],
      },
    },
  ]);

  const output = run(["render", "--session", session]);
  assert.match(output, /browser\/session\/auth internals/);
  assert.doesNotMatch(output, /supersecret123/);
  assert.doesNotMatch(output, /mock-token-123456/);
  assert.doesNotMatch(output, /slash-secret-123456/);
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

test("render omits bare alphabetic secret fields", () => {
  const dir = tempDir();
  const session = path.join(dir, "session.jsonl");
  const secretText = ["api", "_ke", "y: abcdefghijklmnop"].join("");
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
  assert.doesNotMatch(output, /abcdefghijklmnop/);
});

test("render omits dotted secret field values", () => {
  const dir = tempDir();
  const session = path.join(dir, "session.jsonl");
  const secretText = ["api", "_ke", "y: abc", ".defghijkl"].join("");
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
  assert.doesNotMatch(output, /abc\.defghijkl/);
});

test("render omits dotted generic secret field values", () => {
  const dir = tempDir();
  const session = path.join(dir, "session.jsonl");
  const secretText = ["api", "Key: abc", ".defghijkl and sec", "ret: xyz", ".abcdefgh"].join("");
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
  assert.doesNotMatch(output, /abc\.defghijkl/);
  assert.doesNotMatch(output, /xyz\.abcdefgh/);
});

test("render omits malformed quoted and short dotted secret values", () => {
  const dir = tempDir();
  const session = path.join(dir, "session.jsonl");
  const secretText = ["api", "_ke", 'y: "abcdefghijklmnop and pass', "word: pa.ssword"].join("");
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
  assert.doesNotMatch(output, /abcdefghijklmnop/);
  assert.doesNotMatch(output, /pa\.ssword/);
});

test("render omits short unquoted secret fields", () => {
  const dir = tempDir();
  const session = path.join(dir, "session.jsonl");
  const secretText = ["pass", "word: abc123\napi", "_key: x9"].join("");
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
  assert.doesNotMatch(output, /abc123/);
  assert.doesNotMatch(output, /x9/);
});

test("render keeps common short secret-field literals", () => {
  const dir = tempDir();
  const session = path.join(dir, "session.jsonl");
  const text = "password: false\ntoken: null\napiKey: test\nsecret: 2";
  writeJsonl(session, [
    {
      type: "response_item",
      payload: {
        role: "user",
        content: [{ type: "text", text }],
      },
    },
  ]);

  const output = run(["render", "--session", session]);
  assert.match(output, /password: false/);
  assert.match(output, /token: null/);
  assert.match(output, /apiKey: test/);
  assert.match(output, /secret: 2/);
  assert.doesNotMatch(output, /browser\/session\/auth internals/);
});

test("render keeps code references with secret-like property names", () => {
  const dir = tempDir();
  const session = path.join(dir, "session.jsonl");
  writeJsonl(session, [
    {
      type: "response_item",
      payload: {
        role: "user",
        content: [{ type: "text", text: "return { password: user.passwordHash, apiKey: config.apiKey };" }],
      },
    },
  ]);

  const output = run(["render", "--session", session]);
  assert.match(output, /user\.passwordHash/);
  assert.match(output, /config\.apiKey/);
  assert.doesNotMatch(output, /browser\/session\/auth internals/);
});

test("render keeps call expression secret assignments", () => {
  const dir = tempDir();
  const session = path.join(dir, "session.jsonl");
  const multilineAssignment = "let pass" + "word = getPassword()\nnext line";
  writeJsonl(session, [
    {
      type: "response_item",
      payload: {
        role: "user",
        content: [{ type: "text", text: "let password = getPassword()" }],
      },
    },
    {
      type: "response_item",
      payload: {
        role: "user",
        content: [{ type: "text", text: multilineAssignment }],
      },
    },
  ]);

  const output = run(["render", "--session", session]);
  assert.ok(output.includes("let password = getPassword()"));
  assert.match(output, /next line/);
  assert.doesNotMatch(output, /browser\/session\/auth internals/);
});

test("render omits call expression secret literal arguments", () => {
  const dir = tempDir();
  const session = path.join(dir, "session.jsonl");
  const assignment = "let pass" + 'word = getPassword("' + "actual-secret-123" + '")';
  const fallbackAssignment = "let pass" + 'word = getPassword() || "' + "actual-secret-456" + '"';
  const templateAssignment = "let pass" + "word = getPassword(`" + "actual-secret-789" + "`)";
  const bareArgumentAssignment = "let pass" + "word = getPassword(actual-secret-000)";
  const secretIdentifierCall = "let to" + "ken = actualSecret123()";
  const prefixedSecretIdentifierCall = "let to" + "ken = getActualSecret123()";
  writeJsonl(session, [
    {
      type: "response_item",
      payload: {
        role: "user",
        content: [{ type: "text", text: assignment }],
      },
    },
    {
      type: "response_item",
      payload: {
        role: "user",
        content: [{ type: "text", text: fallbackAssignment }],
      },
    },
    {
      type: "response_item",
      payload: {
        role: "user",
        content: [{ type: "text", text: templateAssignment }],
      },
    },
    {
      type: "response_item",
      payload: {
        role: "user",
        content: [{ type: "text", text: bareArgumentAssignment }],
      },
    },
    {
      type: "response_item",
      payload: {
        role: "user",
        content: [{ type: "text", text: secretIdentifierCall }],
      },
    },
    {
      type: "response_item",
      payload: {
        role: "user",
        content: [{ type: "text", text: prefixedSecretIdentifierCall }],
      },
    },
  ]);

  const output = run(["render", "--session", session]);
  assert.match(output, /browser\/session\/auth internals/);
  assert.doesNotMatch(output, /actual-secret-123/);
  assert.doesNotMatch(output, /actual-secret-456/);
  assert.doesNotMatch(output, /actual-secret-789/);
  assert.doesNotMatch(output, /actual-secret-000/);
  assert.doesNotMatch(output, /actualSecret123/);
  assert.doesNotMatch(output, /getActualSecret123/);
});

test("render keeps regex declarations with secret-like names", () => {
  const dir = tempDir();
  const session = path.join(dir, "session.jsonl");
  writeJsonl(session, [
    {
      type: "response_item",
      payload: {
        role: "user",
        content: [{ type: "text", text: "const SERVICE_CREDENTIAL_URL = /postgres:\\/\\/user:pass@example.test/i;" }],
      },
    },
  ]);

  const output = run(["render", "--session", session]);
  assert.match(output, /SERVICE_CREDENTIAL_URL/);
  assert.doesNotMatch(output, /browser\/session\/auth internals/);
});

test("render keeps wrapped diff regex declarations with secret-like names", () => {
  const dir = tempDir();
  const session = path.join(dir, "session.jsonl");
  writeJsonl(session, [
    {
      type: "response_item",
      payload: {
        role: "user",
        content: [{ type: "text", text: "+const SERVICE_CREDENTIAL_URL =\n+  /postgres:\\/\\/user:pass@example.test/i;" }],
      },
    },
  ]);

  const output = run(["render", "--session", session]);
  assert.match(output, /SERVICE_CREDENTIAL_URL/);
  assert.doesNotMatch(output, /browser\/session\/auth internals/);
});

test("render omits prefixed secret-looking values without secret property names", () => {
  const dir = tempDir();
  const session = path.join(dir, "session.jsonl");
  const secretText = ["to", "ken: request.abcdefghijkl and pass", "word: credentials.abcdefghijkl"].join("");
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
  assert.doesNotMatch(output, /request\.abcdefghijkl/);
  assert.doesNotMatch(output, /credentials\.abcdefghijkl/);
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

test("render classifies web fetch tools as network", () => {
  const dir = tempDir();
  const session = path.join(dir, "session.jsonl");
  writeJsonl(session, [
    { type: "response_item", payload: { role: "user", content: [{ type: "text", text: "Fetch reference docs." }] } },
    { type: "response_item", payload: { type: "function_call", name: "WebFetch", arguments: "{}" } },
  ]);

  const output = run(["render", "--session", session]);
  assert.match(output, /tool summary/);
  assert.match(output, /1 network/);
  assert.doesNotMatch(output, /1 read/);
});

test("render omits tool summary for scoped transcripts", () => {
  const dir = tempDir();
  const session = path.join(dir, "session.jsonl");
  writeJsonl(session, [
    { type: "response_item", payload: { role: "user", content: [{ type: "text", text: "Unrelated request." }] } },
    { type: "response_item", payload: { type: "function_call", name: "exec_command", arguments: "npm test" } },
    { type: "response_item", payload: { role: "user", content: [{ type: "text", text: "Scoped transcript guidance." }] } },
  ]);

  const output = run(["render", "--session", session, "--scope-query", "transcript guidance"]);
  assert.match(output, /Scoped transcript guidance/);
  assert.doesNotMatch(output, /tool summary/);
  assert.doesNotMatch(output, /Unrelated request/);
  assert.match(output, /"toolCalls":0/);
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

test("render-thread rejects repo-relative CODEX_BIN", () => {
  assert.throws(
    () =>
      execFileSync(process.execPath, [script, "render-thread", "--thread-id", "fake-thread", "--allow-unscoped"], {
        cwd: path.resolve("."),
        encoding: "utf8",
        env: { ...process.env, CODEX_BIN: "./codex" },
        stdio: ["ignore", "pipe", "pipe"],
      }),
    /refusing relative executable path/,
  );
});

test("render-thread rejects repo-contained absolute CODEX_BIN outside cwd", () => {
  const fakeCodex = path.join(path.resolve("."), ".tmp-agent-transcript-codex");
  fs.writeFileSync(fakeCodex, "#!/bin/sh\nexit 0\n", { mode: 0o700 });
  try {
    assert.throws(
      () =>
        execFileSync(process.execPath, [script, "render-thread", "--thread-id", "fake-thread", "--allow-unscoped"], {
          cwd: os.tmpdir(),
          encoding: "utf8",
          env: { ...process.env, CODEX_BIN: fakeCodex },
          stdio: ["ignore", "pipe", "pipe"],
        }),
      /refusing repo-controlled executable/,
    );
  } finally {
    fs.rmSync(fakeCodex, { force: true });
  }
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

test("render omits generic session cookie material", () => {
  const dir = tempDir();
  const session = path.join(dir, "session.jsonl");
  writeJsonl(session, [
    {
      type: "response_item",
      payload: {
        role: "user",
        content: [{ type: "text", text: "SESSIONID=abcdef1234567890" }],
      },
    },
  ]);

  const output = run(["render", "--session", session]);
  assert.match(output, /browser\/session\/auth internals/);
  assert.doesNotMatch(output, /SESSIONID=/);
  assert.doesNotMatch(output, /abcdef1234567890/);
});

test("render omits quoted cookie assignments", () => {
  const dir = tempDir();
  const session = path.join(dir, "session.jsonl");
  writeJsonl(session, [
    {
      type: "response_item",
      payload: {
        role: "user",
        content: [{ type: "text", text: 'SID="abcdef1234567890"' }],
      },
    },
  ]);

  const output = run(["render", "--session", session]);
  assert.match(output, /browser\/session\/auth internals/);
  assert.doesNotMatch(output, /SID=/);
  assert.doesNotMatch(output, /abcdef1234567890/);
});

test("render omits token auth schemes", () => {
  const dir = tempDir();
  const session = path.join(dir, "session.jsonl");
  writeJsonl(session, [
    {
      type: "response_item",
      payload: {
        role: "user",
        content: [{ type: "text", text: "Authorization: Token abcdefghijklmnop" }],
      },
    },
  ]);

  const output = run(["render", "--session", session]);
  assert.match(output, /browser\/session\/auth internals/);
  assert.doesNotMatch(output, /Authorization: Token/);
  assert.doesNotMatch(output, /abcdefghijklmnop/);
});

test("render keeps benign token prose", () => {
  const dir = tempDir();
  const session = path.join(dir, "session.jsonl");
  writeJsonl(session, [
    {
      type: "response_item",
      payload: {
        role: "user",
        content: [{ type: "text", text: "token classification should stay reviewable" }],
      },
    },
  ]);

  const output = run(["render", "--session", session]);
  assert.match(output, /token classification should stay reviewable/);
  assert.doesNotMatch(output, /browser\/session\/auth internals/);
  assert.doesNotMatch(output, /\[REDACTED_AUTH_HEADER\]/);
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

test("render omits fragment-only OAuth callback URLs", () => {
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
            text: "Callback https://accounts.example.test/oauth2/callback#code=mock-code-123456",
          },
        ],
      },
    },
  ]);

  const output = run(["render", "--session", session]);
  assert.match(output, /browser\/session\/auth internals/);
  assert.doesNotMatch(output, /accounts\.example\.test/);
  assert.doesNotMatch(output, /code=/);
  assert.doesNotMatch(output, /mock-code-123456/);
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
    { type: "response_item", payload: { role: "assistant", content: [{ type: "text", text: "Implemented." }] } },
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
  assert.match(output, /Implemented/);
  assert.doesNotMatch(output, /Unrelated private request/);
});

test("render preserves scoped prompts mentioning instructions", () => {
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
            text: "Following your instructions, please update transcript guidance.",
          },
        ],
      },
    },
    { type: "response_item", payload: { role: "assistant", content: [{ type: "text", text: "Implemented." }] } },
  ]);

  const output = run(["render", "--session", session, "--scope-query", "transcript guidance"]);
  assert.match(output, /Following your instructions/);
  assert.match(output, /Implemented/);
});

test("render does not pull previous user turn for matching assistant", () => {
  const dir = tempDir();
  const session = path.join(dir, "session.jsonl");
  writeJsonl(session, [
    { type: "response_item", payload: { role: "user", content: [{ type: "text", text: "Unrelated private request." }] } },
    { type: "response_item", payload: { role: "assistant", content: [{ type: "text", text: "Implemented transcript guidance." }] } },
  ]);

  const output = run(["render", "--session", session, "--scope-query", "transcript guidance"]);
  assert.match(output, /Implemented transcript guidance/);
  assert.doesNotMatch(output, /Unrelated private request/);
});

test("html preview applies PR scope when rendering candidate sessions", () => {
  const dir = tempDir();
  const root = path.join(dir, "sessions");
  fs.mkdirSync(root);
  const session = path.join(root, "session.jsonl");
  writeJsonl(session, [
    { type: "response_item", payload: { role: "user", content: [{ type: "text", text: "Unrelated GitHub cleanup." }] } },
    { type: "response_item", payload: { role: "user", content: [{ type: "text", text: "Unrelated private request." }] } },
    { type: "response_item", payload: { role: "user", content: [{ type: "text", text: "Scoped transcript guidance." }] } },
    { type: "response_item", payload: { role: "assistant", content: [{ type: "text", text: "Implemented." }] } },
  ]);
  const prs = path.join(dir, "prs.json");
  fs.writeFileSync(
    prs,
    JSON.stringify([
      {
        number: 286,
        title: "Scoped transcript guidance",
        headRefName: "docs/agent-review-transcript-guidance",
        url: "https://github.example.test/repo/pull/286",
      },
    ]),
  );

  const output = run(["html", "--prs", prs, "--root", root, "--min-score", "1"]);
  assert.match(output, /Scoped transcript guidance/);
  assert.match(output, /Implemented/);
  assert.doesNotMatch(output, /Unrelated GitHub cleanup/);
  assert.doesNotMatch(output, /Unrelated private request/);
});

test("html preview rejects generated scopes with no specific terms", () => {
  const dir = tempDir();
  const root = path.join(dir, "sessions");
  fs.mkdirSync(root);
  const session = path.join(root, "session.jsonl");
  writeJsonl(session, [
    { type: "response_item", payload: { role: "user", content: [{ type: "text", text: "Fix UI unrelated private details." }] } },
  ]);
  const prs = path.join(dir, "prs.json");
  fs.writeFileSync(
    prs,
    JSON.stringify([
      {
        number: 12,
        title: "Fix UI",
        headRefName: "ui",
        url: "https://github.example.test/repo/pull/12",
      },
    ]),
  );

  const output = run(["html", "--prs", prs, "--root", root, "--min-score", "1"]);
  assert.match(output, /--scope-query is required for html/);
  assert.doesNotMatch(output, /unrelated private details/);
});
