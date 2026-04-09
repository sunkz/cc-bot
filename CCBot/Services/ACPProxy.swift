// CCBot/Services/ACPProxy.swift
import Foundation

/// Manages the ACP proxy script that wraps Claude Code for IDEA ACP integration.
/// The proxy intercepts `session/request_permission` JSON-RPC messages and
/// notifies CCBot's HTTP server so desktop notifications can fire.
enum ACPProxy {
    static let hooksDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/hooks")

    static let scriptPath: URL = hooksDir.appendingPathComponent("cc-bot-acp-proxy.mjs")

    static var proxyScript: String { #"""
    #!/usr/bin/env node
    // cc-bot-acp-proxy.mjs
    // ACP Proxy — wraps any ACP server command, intercepts
    // session/request_permission JSON-RPC messages and notifies CCBot.
    //
    // Usage in ~/.jetbrains/acp.json:
    //   {
    //     "command": "~/.claude/hooks/cc-bot-acp-proxy.mjs",
    //     "args": ["/opt/homebrew/bin/npx", "-y", "@zed-industries/claude-agent-acp"]
    //   }
    //
    // The first arg is the real command, remaining args are passed through.
    //
    // Environment:
    //   CCBOT_PORT — CCBot HTTP port (default: 62400)

    import { spawn } from 'node:child_process';
    import { createInterface } from 'node:readline';
    import http from 'node:http';
    import { readFileSync } from 'node:fs';

    const CCBOT_PORT = parseInt(process.env.CCBOT_PORT || '\#(Constants.serverPort)', 10);
    const CCBOT_TOKEN = (() => { try { return readFileSync(
      `${process.env.HOME}/.claude/hooks/.ccbot-auth`, 'utf8').trim(); } catch { return ''; } })();

    // First arg = real command, rest = its args
    const realCmd = process.argv[2];
    const realArgs = process.argv.slice(3);

    if (!realCmd) {
      process.stderr.write(
        '[cc-bot-acp-proxy] Usage: cc-bot-acp-proxy.mjs <command> [args...]\n' +
        '[cc-bot-acp-proxy] Example: cc-bot-acp-proxy.mjs /opt/homebrew/bin/npx -y @zed-industries/claude-agent-acp\n'
      );
      process.exit(1);
    }

    process.stderr.write(`[cc-bot-acp-proxy] Wrapping: ${realCmd} ${realArgs.join(' ')}\n`);

    // Spawn the real ACP server, forwarding stderr directly
    const child = spawn(realCmd, realArgs, {
      stdio: ['pipe', 'pipe', 'inherit'],
      env: { ...process.env },
    });

    child.on('error', (err) => {
      process.stderr.write(`[cc-bot-acp-proxy] Failed to spawn: ${err.message}\n`);
      process.exit(1);
    });

    // Forward parent stdin → child stdin
    process.stdin.pipe(child.stdin);

    // Notify CCBot about a permission request (fire-and-forget)
    function notifyCCBot(toolName, cwd) {
      const toolInfo = toolName && toolName !== 'unknown' ? `${toolName} ` : '';
      const body = JSON.stringify({
        message: `ACP: ${toolInfo}需要权限确认`,
        cwd: cwd || process.cwd(),
      });
      const req = http.request({
        hostname: '127.0.0.1',
        port: CCBOT_PORT,
        path: '/hook/notification',
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body), 'Authorization': `Bearer ${CCBOT_TOKEN}` },
        timeout: 2000,
      });
      req.on('error', () => {}); // swallow — CCBot may not be running
      req.end(body);
    }

    // Read child stdout line by line, inspect and forward
    const rl = createInterface({ input: child.stdout, crlfDelay: Infinity });

    rl.on('line', (line) => {
      // Always forward the line immediately
      process.stdout.write(line + '\n');

      // Quick check before parsing
      if (!line.includes('request_permission')) return;

      try {
        const msg = JSON.parse(line);
        if (msg.method === 'session/request_permission' || msg.method === 'request_permission') {
          const toolName = msg.params?.toolCallUpdate?.toolName
            || msg.params?.tool_name
            || 'unknown';
          const cwd = msg.params?.cwd || '';
          process.stderr.write(`[cc-bot-acp-proxy] Permission request detected: ${toolName}\n`);
          notifyCCBot(toolName, cwd);
        }
      } catch {
        // Not valid JSON or not a permission request — ignore
      }
    });

    // Propagate exit
    child.on('exit', (code) => process.exit(code ?? 1));
    process.on('SIGTERM', () => child.kill('SIGTERM'));
    process.on('SIGINT', () => child.kill('SIGINT'));
    """# }

    static func install() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        try proxyScript.write(to: scriptPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)
    }

    static func uninstall() throws {
        try FileUtilities.removeItemIfExists(scriptPath)
    }

    static func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: scriptPath.path)
    }

    /// Overwrite script with latest version if already installed.
    static func updateIfInstalled() throws {
        guard isInstalled() else { return }
        try proxyScript.write(to: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)
    }
}
