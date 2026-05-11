/**
 * extension.ts — PRODUCT-056 slice 1
 *
 * VS Code extension entry point: on activation, launch `chump --acp` as an
 * ACP stdio backend, complete the initialize handshake, and surface connection
 * state in the status bar.
 *
 * Slice 1 scope (PRODUCT-056): scaffold + connect + status bar.
 * Chat panel → PRODUCT-057. Tool approval → PRODUCT-058.
 */

import * as vscode from 'vscode';
import { AcpClient, AcpStatus } from './acpClient';

let client: AcpClient | undefined;
let statusBarItem: vscode.StatusBarItem | undefined;

export async function activate(context: vscode.ExtensionContext): Promise<void> {
  statusBarItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 100);
  statusBarItem.command = 'chump.showStatus';
  statusBarItem.text = '$(loading~spin) Chump';
  statusBarItem.tooltip = 'Chump ACP backend — connecting…';
  statusBarItem.show();
  context.subscriptions.push(statusBarItem);

  context.subscriptions.push(
    vscode.commands.registerCommand('chump.reconnect', () => reconnect(context)),
    vscode.commands.registerCommand('chump.showStatus', showStatus),
  );

  await connect(context);
}

export function deactivate(): void {
  client?.dispose();
}

// ── Connection lifecycle ──────────────────────────────────────────────────────

async function connect(context: vscode.ExtensionContext): Promise<void> {
  client?.dispose();

  const config = vscode.workspace.getConfiguration('chump');
  const binaryPath: string = config.get('binaryPath') ?? 'chump';
  const extraArgs: string[] = config.get('args') ?? ['--acp'];

  client = new AcpClient(binaryPath, extraArgs);

  client.on('status', (s: AcpStatus) => updateStatusBar(s));
  client.on('error', (err: Error) => {
    updateStatusBar('error');
    console.error('[vscode-chump] ACP error:', err.message);
  });
  client.on('notification', (method: string, params: unknown) => {
    // Slice 1: log notifications only. PRODUCT-057 will handle session/progress.
    console.debug('[vscode-chump] notification:', method, params);
  });

  context.subscriptions.push({ dispose: () => client?.dispose() });

  const workspaceRoot = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;

  try {
    const result = await client.connect(workspaceRoot);
    console.log(
      `[vscode-chump] connected — agent=${result.agentInfo.name} v${result.agentInfo.version}`,
      `protocol=${result.protocolVersion}`,
    );
    updateStatusBar('connected', result.agentInfo.version);
  } catch (err) {
    updateStatusBar('error');
    console.error('[vscode-chump] connect failed:', err);
    vscode.window.showWarningMessage(
      `Chump: failed to connect to ACP backend — ${(err as Error).message}`,
      'Retry',
    ).then(choice => {
      if (choice === 'Retry') { reconnect(context); }
    });
  }
}

async function reconnect(context: vscode.ExtensionContext): Promise<void> {
  await connect(context);
}

function showStatus(): void {
  const s = client?.status ?? 'disconnected';
  vscode.window.showInformationMessage(`Chump ACP backend: ${s}`);
}

// ── Status bar ────────────────────────────────────────────────────────────────

function updateStatusBar(status: AcpStatus, version?: string): void {
  if (!statusBarItem) { return; }
  switch (status) {
    case 'connected':
      statusBarItem.text = `$(check) Chump${version ? ` v${version}` : ''}`;
      statusBarItem.tooltip = 'Chump ACP backend connected';
      statusBarItem.color = undefined;
      break;
    case 'connecting':
      statusBarItem.text = '$(loading~spin) Chump';
      statusBarItem.tooltip = 'Chump ACP backend — connecting…';
      statusBarItem.color = undefined;
      break;
    case 'error':
      statusBarItem.text = '$(error) Chump';
      statusBarItem.tooltip = 'Chump ACP backend error — click to reconnect';
      statusBarItem.color = new vscode.ThemeColor('statusBarItem.errorForeground');
      break;
    case 'disconnected':
      statusBarItem.text = '$(circle-slash) Chump';
      statusBarItem.tooltip = 'Chump ACP backend disconnected — click to reconnect';
      statusBarItem.color = undefined;
      break;
  }
}
