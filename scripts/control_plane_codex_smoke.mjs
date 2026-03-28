#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";

export function buildDefaultOptions() {
  const runNonce = `${Date.now()}-${randomUUID().slice(0, 8)}`;

  return {
    url: process.env.LEMON_WS_URL || "ws://127.0.0.1:4040/ws",
    agentId: process.env.LEMON_AGENT_ID || "default",
    timeoutMs: Number(process.env.LEMON_SMOKE_TIMEOUT_MS || 120000),
    sessionA: `agent:default:codex-op-a-${runNonce}`,
    sessionB: `agent:default:codex-op-b-${runNonce}`,
    configPath: process.env.LEMON_CONFIG_PATH || path.join(os.homedir(), ".lemon", "config.toml"),
    codexBin: process.env.LEMON_CODEX_BIN || "codex",
    checkOnly: false,
    skipPreflight: false,
  };
}

function usage() {
  return `Usage: ./scripts/control_plane_codex_smoke.mjs [options]

Options:
  --url <ws-url>          Control-plane WebSocket URL
  --agent-id <id>         Agent id to use (default: default)
  --timeout-ms <ms>       Per-run timeout in milliseconds
  --session-a <key>       Session key for Codex smoke lane A
  --session-b <key>       Session key for Codex smoke lane B
  --config-path <path>    Lemon config path (default: ~/.lemon/config.toml)
  --codex-bin <path>      Codex executable to probe (default: codex)
  --check-only            Run preflight checks only; do not connect to control plane
  --skip-preflight        Skip local config/codex checks
  --help                  Show this help
`;
}

export function parseArgs(argv) {
  const options = buildDefaultOptions();

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const next = argv[i + 1];

    switch (arg) {
      case "--help":
        console.log(usage());
        process.exit(0);
        break;
      case "--url":
        options.url = next;
        i += 1;
        break;
      case "--agent-id":
        options.agentId = next;
        i += 1;
        break;
      case "--timeout-ms":
        options.timeoutMs = Number(next);
        i += 1;
        break;
      case "--session-a":
        options.sessionA = next;
        i += 1;
        break;
      case "--session-b":
        options.sessionB = next;
        i += 1;
        break;
      case "--config-path":
        options.configPath = next;
        i += 1;
        break;
      case "--codex-bin":
        options.codexBin = next;
        i += 1;
        break;
      case "--check-only":
        options.checkOnly = true;
        break;
      case "--skip-preflight":
        options.skipPreflight = true;
        break;
      default:
        throw new Error(`Unknown argument: ${arg}`);
    }
  }

  if (!Number.isFinite(options.timeoutMs) || options.timeoutMs <= 0) {
    throw new Error(`Invalid --timeout-ms: ${options.timeoutMs}`);
  }

  return options;
}

function parseTopLevelTables(toml) {
  const tables = new Map();
  let current = null;

  for (const rawLine of toml.split(/\r?\n/u)) {
    const line = rawLine.trim();

    if (!line || line.startsWith("#")) {
      continue;
    }

    const tableMatch = line.match(/^\[([^\]]+)\]$/u);
    if (tableMatch) {
      current = tableMatch[1];
      if (!tables.has(current)) {
        tables.set(current, []);
      }
      continue;
    }

    if (current) {
      tables.get(current).push(line);
    }
  }

  return tables;
}

function runPreflight(options) {
  if (options.skipPreflight) {
    return { skipped: true };
  }

  if (!fs.existsSync(options.configPath)) {
    throw new Error(
      `Missing Lemon config: ${options.configPath}\n` +
        "Create it from examples/config.example.toml and add a minimal [runtime.cli.codex] and [gateway] setup before running the Codex smoke.",
    );
  }

  const toml = fs.readFileSync(options.configPath, "utf8");
  const tables = parseTopLevelTables(toml);

  const codexCli = tables.get("runtime.cli.codex");
  if (!codexCli) {
    throw new Error(
      `Config ${options.configPath} is missing [runtime.cli.codex]. ` +
        "Add the Codex CLI block so the runtime uses an explicit Codex runner configuration.",
    );
  }

  const gateway = tables.get("gateway");
  if (!gateway) {
    throw new Error(
      `Config ${options.configPath} is missing [gateway]. ` +
        "The control-plane Codex smoke requires a runnable gateway configuration.",
    );
  }

  const codexProbe = spawnSync(options.codexBin, ["--version"], {
    encoding: "utf8",
    env: process.env,
  });

  if (codexProbe.error) {
    throw new Error(`Failed to execute Codex CLI ${options.codexBin}: ${codexProbe.error.message}`);
  }

  if (codexProbe.status !== 0) {
    throw new Error(
      `Codex CLI probe failed for ${options.codexBin}: ${codexProbe.stderr || codexProbe.stdout || `exit ${codexProbe.status}`}`,
    );
  }

  return {
    configPath: options.configPath,
    codexBin: options.codexBin,
    version: (codexProbe.stdout || codexProbe.stderr || "").trim(),
  };
}

class ControlPlaneClient {
  constructor(url) {
    this.url = url;
    this.socket = null;
    this.connected = false;
    this.pending = new Map();
    this.readyPromise = null;
  }

  async connect(timeoutMs) {
    this.readyPromise = new Promise((resolve, reject) => {
      const socket = new WebSocket(this.url);
      this.socket = socket;

      const timer = setTimeout(() => {
        reject(new Error(`Timed out waiting for hello-ok from ${this.url}`));
      }, timeoutMs);

      socket.addEventListener("open", () => {
        this.#sendRaw({
          type: "req",
          id: randomUUID(),
          method: "connect",
          params: {
            role: "operator",
            client: { id: "codex-smoke" },
          },
        });
      });

      socket.addEventListener("message", (event) => {
        const frame = JSON.parse(String(event.data));

        if (frame.type === "hello-ok") {
          clearTimeout(timer);
          this.connected = true;
          resolve(frame);
          return;
        }

        if (frame.type === "res") {
          const pending = this.pending.get(frame.id);

          if (!pending) {
            return;
          }

          this.pending.delete(frame.id);

          if (frame.ok) {
            pending.resolve(frame.payload);
          } else {
            pending.reject(new Error(JSON.stringify(frame.error || frame)));
          }
        }
      });

      socket.addEventListener("error", (event) => {
        clearTimeout(timer);
        reject(new Error(`WebSocket error: ${event.message || "unknown"}`));
      });

      socket.addEventListener("close", (event) => {
        const error = new Error(`WebSocket closed: code=${event.code} reason=${event.reason || ""}`);

        clearTimeout(timer);

        if (!this.connected) {
          reject(error);
        }

        for (const pending of this.pending.values()) {
          pending.reject(error);
        }

        this.pending.clear();
        this.connected = false;
      });
    });

    return this.readyPromise;
  }

  async call(method, params, timeoutMs) {
    if (!this.socket || !this.connected) {
      throw new Error("WebSocket is not connected");
    }

    const id = randomUUID();

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`Timed out waiting for ${method}`));
      }, timeoutMs);

      this.pending.set(id, {
        resolve: (payload) => {
          clearTimeout(timer);
          resolve(payload);
        },
        reject: (error) => {
          clearTimeout(timer);
          reject(error);
        },
      });

      this.#sendRaw({
        type: "req",
        id,
        method,
        params,
      });
    });
  }

  close() {
    if (this.socket) {
      this.socket.close();
    }
  }

  #sendRaw(frame) {
    this.socket.send(JSON.stringify(frame));
  }
}

function extractRunId(payload) {
  return payload.runId || payload.run_id;
}

function extractAnswer(payload) {
  return payload.answer || "";
}

async function waitForRun(client, runId, timeoutMs) {
  return client.call("agent.wait", { runId, timeoutMs }, timeoutMs + 1000);
}

async function submitAgentRun(client, sessionKey, agentId, prompt, timeoutMs) {
  const payload = await client.call(
    "agent",
    {
      prompt,
      agentId,
      sessionKey,
      engineId: "codex",
    },
    timeoutMs,
  );

  const runId = extractRunId(payload);

  if (!runId) {
    throw new Error(`agent response missing run id: ${JSON.stringify(payload)}`);
  }

  return { runId, payload };
}

async function submitFollowUp(client, sessionKey, agentId, prompt, timeoutMs) {
  const payload = await client.call(
    "chat.send",
    {
      prompt,
      agentId,
      sessionKey,
      queueMode: "collect",
    },
    timeoutMs,
  );

  const runId = extractRunId(payload);

  if (!runId) {
    throw new Error(`chat.send response missing run id: ${JSON.stringify(payload)}`);
  }

  return { runId, payload };
}

function assertAnswer(label, payload, expected) {
  const answer = extractAnswer(payload);
  const ok = payload.ok;

  if (ok !== true) {
    throw new Error(`${label} failed: ${JSON.stringify(payload)}`);
  }

  if (!answer.includes(expected)) {
    throw new Error(`${label} answer mismatch: expected ${expected}, got ${answer}`);
  }
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const preflight = runPreflight(options);

  if (options.checkOnly) {
    if (preflight.skipped) {
      console.log("CODEX_SMOKE_PREFLIGHT_SKIPPED");
    } else {
      console.log(
        `CODEX_SMOKE_PREFLIGHT_OK config=${preflight.configPath} codex=${preflight.codexBin} version=${preflight.version}`,
      );
    }

    return;
  }

  const client = new ControlPlaneClient(options.url);

  try {
    const hello = await client.connect(options.timeoutMs);
    console.log(`Connected to ${options.url} as ${hello.auth?.role || "unknown"}`);

    const aPrompt =
      "Remember the word ALBATROSS. Reply exactly CODEX_SESSION_A_FINAL_OK and nothing else.";
    const bPrompt =
      "Remember the word MANGROVE. Reply exactly CODEX_SESSION_B_FINAL_OK and nothing else.";
    const followUpPrompt =
      "What word did I ask you to remember earlier? If it was ALBATROSS reply exactly CODEX_SESSION_A_FINAL_FOLLOWUP_OK and nothing else. Otherwise reply FAIL.";

    const [runA, runB] = await Promise.all([
      submitAgentRun(client, options.sessionA, options.agentId, aPrompt, options.timeoutMs),
      submitAgentRun(client, options.sessionB, options.agentId, bPrompt, options.timeoutMs),
    ]);

    console.log(`Session A run id: ${runA.runId}`);
    console.log(`Session B run id: ${runB.runId}`);

    const [resultA, resultB] = await Promise.all([
      waitForRun(client, runA.runId, options.timeoutMs),
      waitForRun(client, runB.runId, options.timeoutMs),
    ]);

    assertAnswer("session A", resultA, "CODEX_SESSION_A_FINAL_OK");
    assertAnswer("session B", resultB, "CODEX_SESSION_B_FINAL_OK");

    const followUp = await submitFollowUp(
      client,
      options.sessionA,
      options.agentId,
      followUpPrompt,
      options.timeoutMs,
    );

    console.log(`Session A follow-up run id: ${followUp.runId}`);

    const followUpResult = await waitForRun(client, followUp.runId, options.timeoutMs);
    assertAnswer("session A follow-up", followUpResult, "CODEX_SESSION_A_FINAL_FOLLOWUP_OK");

    console.log("CODEX_SMOKE_OK");
  } finally {
    client.close();
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    console.error(error.stack || String(error));
    process.exitCode = 1;
  });
}
