/**
 * acpClient.ts — PRODUCT-056 slice 1
 *
 * Minimal ACP stdio client: launches `chump --acp` as a child process,
 * writes JSON-RPC requests to stdin, reads newline-delimited JSON responses
 * from stdout. Slice 1 scope: connect + initialize handshake only.
 */

import * as cp from 'child_process';
import { EventEmitter } from 'events';

export interface AcpCapabilities {
  tools?: boolean;
  streaming?: boolean;
  modes?: string[];
}

export interface AcpInitializeResult {
  protocolVersion: string;
  capabilities: AcpCapabilities;
  agentInfo: { name: string; version: string };
}

export type AcpStatus = 'disconnected' | 'connecting' | 'connected' | 'error';

/**
 * Thin JSON-RPC-over-stdio wrapper for the chump ACP server.
 * Emits: 'status' (AcpStatus), 'notification' (method, params), 'error' (Error).
 */
export class AcpClient extends EventEmitter {
  private proc: cp.ChildProcess | null = null;
  private buffer = '';
  private nextId = 1;
  private pending = new Map<number, { resolve: (v: unknown) => void; reject: (e: Error) => void }>();
  private _status: AcpStatus = 'disconnected';

  get status(): AcpStatus { return this._status; }

  constructor(
    private readonly binaryPath: string,
    private readonly extraArgs: string[],
  ) {
    super();
  }

  /** Launch chump --acp and complete the initialize handshake. */
  async connect(workspaceFolderPath?: string): Promise<AcpInitializeResult> {
    this._setStatus('connecting');

    const args = ['--acp', ...this.extraArgs.filter(a => a !== '--acp')];
    this.proc = cp.spawn(this.binaryPath, args, {
      stdio: ['pipe', 'pipe', 'inherit'], // stdin, stdout → us; stderr → terminal
      cwd: workspaceFolderPath,
      env: { ...process.env },
    });

    this.proc.on('error', (err: Error) => {
      this._setStatus('error');
      this.emit('error', err);
    });

    this.proc.on('exit', (code, signal) => {
      this._setStatus('disconnected');
      const msg = signal ? `signal ${signal}` : `code ${code}`;
      this.emit('error', new Error(`chump --acp exited (${msg})`));
    });

    this.proc.stdout!.on('data', (chunk: Buffer) => {
      this.buffer += chunk.toString('utf8');
      this._drainBuffer();
    });

    // ACP initialize request (V1 spec: client → agent)
    const result = await this._call('initialize', {
      protocolVersion: '0.1',
      clientInfo: { name: 'vscode-chump', version: '0.1.0' },
      capabilities: { tools: true, streaming: true },
      workspace: workspaceFolderPath ? { rootUri: `file://${workspaceFolderPath}` } : undefined,
    }) as AcpInitializeResult;

    this._setStatus('connected');
    return result;
  }

  /** Send a JSON-RPC request and return the result. */
  request(method: string, params?: unknown): Promise<unknown> {
    return this._call(method, params);
  }

  /** Send a JSON-RPC notification (no response expected). */
  notify(method: string, params?: unknown): void {
    this._write({ jsonrpc: '2.0', method, params });
  }

  dispose(): void {
    this.proc?.stdin?.end();
    this.proc?.kill();
    this.proc = null;
    this._setStatus('disconnected');
  }

  // ── private ──────────────────────────────────────────────────────────────

  private _call(method: string, params?: unknown): Promise<unknown> {
    return new Promise((resolve, reject) => {
      const id = this.nextId++;
      this.pending.set(id, { resolve, reject });
      this._write({ jsonrpc: '2.0', id, method, params });
      // Timeout after 15s to avoid hanging forever on a dead backend
      setTimeout(() => {
        if (this.pending.has(id)) {
          this.pending.delete(id);
          reject(new Error(`ACP request timed out: ${method} (id=${id})`));
        }
      }, 15_000);
    });
  }

  private _write(msg: object): void {
    if (!this.proc?.stdin?.writable) {
      throw new Error('ACP stdin not writable — is chump running?');
    }
    this.proc.stdin.write(JSON.stringify(msg) + '\n');
  }

  private _drainBuffer(): void {
    let idx: number;
    while ((idx = this.buffer.indexOf('\n')) !== -1) {
      const line = this.buffer.slice(0, idx).trim();
      this.buffer = this.buffer.slice(idx + 1);
      if (!line) { continue; }
      let msg: Record<string, unknown>;
      try { msg = JSON.parse(line); } catch { continue; }

      if ('id' in msg && this.pending.has(msg['id'] as number)) {
        const { resolve, reject } = this.pending.get(msg['id'] as number)!;
        this.pending.delete(msg['id'] as number);
        if (msg['error']) {
          reject(new Error(String((msg['error'] as Record<string, unknown>)['message'] ?? msg['error'])));
        } else {
          resolve(msg['result']);
        }
      } else if ('method' in msg) {
        // Notification / server-initiated request
        this.emit('notification', msg['method'], msg['params']);
      }
    }
  }

  private _setStatus(s: AcpStatus): void {
    if (this._status !== s) {
      this._status = s;
      this.emit('status', s);
    }
  }
}
