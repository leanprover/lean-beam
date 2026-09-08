#!/usr/bin/env node

// Copyright (c) 2026 Lean FRO LLC. All rights reserved.
// Released under Apache 2.0 license as described in the file LICENSE.
// Author: Emilio J. Gallego Arias

import { pathToFileURL } from "node:url";
import { join, resolve } from "node:path";
import { writeFile } from "node:fs/promises";
import { createRequire } from "node:module";

const MODERN_PROTOCOL_VERSION = "2026-07-28";

function fail(message) {
  throw new Error(message);
}

function require(condition, message) {
  if (!condition) fail(message);
}

function option(name) {
  const index = process.argv.indexOf(name);
  if (index === -1 || index + 1 >= process.argv.length) {
    fail(`missing required option ${name}`);
  }
  return process.argv[index + 1];
}

function sdkModule(sdkRoot, name) {
  const requireFromSdk = createRequire(join(sdkRoot, "package.json"));
  const packageName = name === "stdio" ? "@modelcontextprotocol/client/stdio" : "@modelcontextprotocol/client";
  return pathToFileURL(requireFromSdk.resolve(packageName)).href;
}

function structured(result, label) {
  require(result?.isError !== true, `${label} returned an MCP tool error: ${JSON.stringify(result)}`);
  require(
    result?.structuredContent !== null && typeof result?.structuredContent === "object",
    `${label} omitted structuredContent: ${JSON.stringify(result)}`,
  );
  return result.structuredContent;
}

const sdkRoot = resolve(option("--sdk-root"));
const server = resolve(option("--server"));
const serverCwd = resolve(option("--server-cwd"));
const root = resolve(option("--root"));
const leanCmd = resolve(option("--lean-cmd"));
const leanPlugin = resolve(option("--lean-plugin"));
const modeName = option("--mode");
require(modeName === "auto" || modeName === "pin", `unknown negotiation mode ${modeName}`);

const { Client } = await import(sdkModule(sdkRoot, "client"));
const { StdioClientTransport } = await import(sdkModule(sdkRoot, "stdio"));

const transport = new StdioClientTransport({
  command: server,
  args: ["--lean-cmd", leanCmd, "--lean-plugin", leanPlugin],
  cwd: serverCwd,
  stderr: "pipe",
});
let serverStderr = "";
transport.stderr?.setEncoding("utf8");
transport.stderr?.on("data", (chunk) => {
  serverStderr += chunk;
});

const client = new Client(
  { name: "lean-beam-modern-sdk-test", version: "1" },
  {
    versionNegotiation: {
      mode: modeName === "auto" ? "auto" : { pin: MODERN_PROTOCOL_VERSION },
    },
  },
);

const diagnosticLogs = [];
client.setNotificationHandler("notifications/message", (notification) => {
  if (notification.params?.logger === "lean.diagnostic") {
    diagnosticLogs.push(notification.params);
  }
});

let testError;
try {
  if (modeName === "pin") {
    const warningText = (name) => [
      `def ${name}Value : Nat := 1`,
      "",
      "set_option linter.unusedVariables true in",
      `theorem ${name}Warning (n : Nat) : True := by`,
      "  trivial",
      "",
    ].join("\n");
    await writeFile(join(root, "SdkSilentWarning.lean"), warningText("sdkSilent"), "utf8");
    await writeFile(join(root, "SdkLoggedWarning.lean"), warningText("sdkLogged"), "utf8");
  }
  await client.connect(transport);
  require(client.getProtocolEra() === "modern", `unexpected protocol era: ${client.getProtocolEra()}`);
  require(
    client.getNegotiatedProtocolVersion() === MODERN_PROTOCOL_VERSION,
    `unexpected protocol version: ${client.getNegotiatedProtocolVersion()}`,
  );
  const discovery = client.getDiscoverResult();
  require(
    JSON.stringify(discovery?.supportedVersions) === JSON.stringify([MODERN_PROTOCOL_VERSION]),
    `unexpected discovery result: ${JSON.stringify(discovery)}`,
  );

  const listed = await client.listTools();
  const names = new Set(listed.tools.map((tool) => tool.name));
  require(names.has("beam_version"), "tools/list omitted beam_version");
  require(names.has("lean_sync"), "tools/list omitted lean_sync");

  const version = structured(
    await client.callTool({ name: "beam_version", arguments: {} }),
    "beam_version",
  );
  require(
    version.mcp_protocol === MODERN_PROTOCOL_VERSION,
    `beam_version reported the wrong MCP version: ${JSON.stringify(version)}`,
  );

  const progress = [];
  const sync = structured(
    await client.callTool(
      {
        name: "lean_sync",
        arguments: {
          workspace: { root },
          path: "PositionEmptyLine.lean",
        },
      },
      {
        onprogress: (notification) => progress.push(notification),
      },
    ),
    "lean_sync",
  );
  require(typeof sync.snapshot === "string", `lean_sync omitted its source snapshot: ${JSON.stringify(sync)}`);
  require(progress.length > 0, "the SDK did not receive lean_sync progress notifications");
  for (let index = 1; index < progress.length; index += 1) {
    require(
      progress[index].progress > progress[index - 1].progress,
      `lean_sync progress was not strictly increasing: ${JSON.stringify(progress)}`,
    );
  }
  require(
    diagnosticLogs.length === 0,
    `modern request emitted diagnostic logs without request-scoped opt-in: ${JSON.stringify(diagnosticLogs)}`,
  );

  if (modeName === "pin") {
    structured(
      await client.callTool({
        name: "lean_sync",
        arguments: {
          workspace: { root },
          path: "SdkSilentWarning.lean",
          diagnostic_scope: "all",
        },
      }),
      "silent warning lean_sync",
    );
    require(
      diagnosticLogs.length === 0,
      `official SDK request without logLevel received diagnostic logs: ${JSON.stringify(diagnosticLogs)}`,
    );

    structured(
      await client.callTool({
        name: "lean_sync",
        arguments: {
          workspace: { root },
          path: "SdkLoggedWarning.lean",
          diagnostic_scope: "all",
        },
        _meta: {
          "io.modelcontextprotocol/logLevel": "warning",
        },
      }),
      "logged warning lean_sync",
    );
    require(
      diagnosticLogs.some((message) => message.level === "warning"),
      `official SDK did not receive request-scoped warning logs: ${JSON.stringify(diagnosticLogs)}`,
    );
  }

  console.log(
    JSON.stringify({
      mode: modeName,
      era: client.getProtocolEra(),
      version: client.getNegotiatedProtocolVersion(),
      toolCount: listed.tools.length,
      progressUpdates: progress.length,
    }),
  );
} catch (error) {
  testError = error;
} finally {
  await client.close();
}

require(transport.pid === null, `official SDK transport did not reap lean-beam-mcp (pid ${transport.pid})`);
if (testError !== undefined) {
  fail(`${testError.stack ?? testError}\nlean-beam-mcp stderr:\n${serverStderr || "<empty>"}`);
}
require(serverStderr === "", `lean-beam-mcp wrote unexpected stderr:\n${serverStderr}`);
