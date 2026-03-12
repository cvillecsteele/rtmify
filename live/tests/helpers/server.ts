import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const sysRoot = path.resolve(here, '..', '..', '..');

export type StartedServer = {
  baseUrl: string;
  child: ChildProcessWithoutNullStreams;
  output(): string;
  stop(): Promise<void>;
};

function binaryPath(): string {
  return process.env.RTMIFY_LIVE_BIN || path.join(sysRoot, 'zig-out', 'bin', 'rtmify-live');
}

async function waitForServer(basePort: number, timeoutMs = 20_000): Promise<string> {
  const deadline = Date.now() + timeoutMs;
  let lastError = 'server did not respond';
  while (Date.now() < deadline) {
    for (let offset = 0; offset <= 10; offset += 1) {
      const baseUrl = `http://127.0.0.1:${basePort + offset}`;
      try {
        const res = await fetch(`${baseUrl}/api/status`, { cache: 'no-store' });
        if (res.ok) return baseUrl;
        lastError = `HTTP ${res.status}`;
      } catch (err) {
        lastError = err instanceof Error ? err.message : String(err);
      }
    }
    await new Promise((r) => setTimeout(r, 200));
  }
  throw new Error(`Timed out waiting for port ${basePort}: ${lastError}`);
}

export async function startServer(options: {
  dbPath: string;
  port: number;
  repoPath?: string;
  extraArgs?: string[];
}): Promise<StartedServer> {
  const args = ['--db', options.dbPath, '--port', String(options.port), '--no-browser'];
  if (options.repoPath) args.push('--repo', options.repoPath);
  if (options.extraArgs) args.push(...options.extraArgs);

  const logPath = path.join(path.dirname(options.dbPath), 'server.log');
  const child = spawn(binaryPath(), args, {
    cwd: sysRoot,
    env: {
      ...process.env,
      RTMIFY_LOG_PATH: logPath,
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  let output = '';
  child.stdout.on('data', (d) => {
    output += d.toString();
  });
  child.stderr.on('data', (d) => {
    output += d.toString();
  });

  let baseUrl = `http://127.0.0.1:${options.port}`;
  try {
    baseUrl = await waitForServer(options.port);
  } catch (err) {
    child.kill('SIGKILL');
    throw new Error(`${String(err)}\n--- server output ---\n${output}`);
  }

  return {
    baseUrl,
    child,
    output: () => output,
    stop: async () => {
      if (child.killed || child.exitCode !== null) return;
      child.kill('SIGTERM');
      await new Promise<void>((resolve) => {
        const timer = setTimeout(() => {
          if (child.exitCode === null) child.kill('SIGKILL');
          resolve();
        }, 2000);
        child.once('exit', () => {
          clearTimeout(timer);
          resolve();
        });
      });
    },
  };
}
