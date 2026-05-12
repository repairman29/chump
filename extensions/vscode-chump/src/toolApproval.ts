/**
 * toolApproval.ts — PRODUCT-058 slice 3
 *
 * Handles ACP `session/request_permission` server-initiated requests:
 *   - Shows a VS Code quickpick with approve / deny / always-approve options
 *   - For file-read tools: opens the target file in the editor for inspection
 *   - For file-write/patch tools: opens the file + previews via WorkspaceEdit
 *   - For run_cli tools: shows the command in the integrated terminal
 *   - Responds to chump --acp with the user's outcome
 */

import * as vscode from 'vscode';
import * as path from 'path';
import { AcpClient } from './acpClient';

interface PermissionOption {
  id: string;
  label: string;
  kind: string;
}

interface RequestPermissionParams {
  sessionId: string;
  toolCall: {
    toolCallId: string;
    toolName: string;
    input: Record<string, unknown>;
  };
  options: PermissionOption[];
}

const FILE_READ_TOOLS = new Set([
  'read_file', 'fs/read_text_file', 'fs_read_text_file', 'view',
]);

const FILE_WRITE_TOOLS = new Set([
  'write_file', 'fs/write_text_file', 'fs_write_text_file', 'patch_file',
  'create_file', 'str_replace_editor', 'edit_file',
]);

const TERMINAL_TOOLS = new Set([
  'run_cli', 'run_terminal_command', 'bash', 'execute_command', 'computer',
]);

/** Attaches permission-request handling to an AcpClient. Call once per client instance. */
export function attachToolApprovalHandler(client: AcpClient): void {
  client.on('request', async (method: string, id: unknown, params: unknown) => {
    if (method !== 'session/request_permission') { return; }
    await handlePermissionRequest(client, id, params as RequestPermissionParams);
  });
}

async function handlePermissionRequest(
  client: AcpClient,
  id: unknown,
  params: RequestPermissionParams,
): Promise<void> {
  const { toolCall, options } = params;
  const { toolName, input } = toolCall;

  // Side-effect previews (best-effort; don't block approval on failure)
  await showToolContext(toolName, input).catch(() => undefined);

  const pickItems = options.map(opt => ({
    label: opt.label,
    description: opt.kind === 'deny' ? '$(circle-slash)' : opt.kind === 'allow_always' ? '$(shield)' : '$(check)',
    optionId: opt.id,
  }));

  const inputSummary = summariseInput(toolName, input);
  const picked = await vscode.window.showQuickPick(pickItems, {
    title: `Chump: Allow \`${toolName}\`?`,
    placeHolder: inputSummary,
    ignoreFocusOut: true,
  });

  if (!picked) {
    client.respond(id, { outcome: { type: 'cancelled' } });
  } else {
    client.respond(id, { outcome: { type: 'selected', optionId: picked.optionId } });
  }
}

/** Open contextual editor/terminal preview before the quickpick appears. */
async function showToolContext(toolName: string, input: Record<string, unknown>): Promise<void> {
  const filePath = (input['path'] ?? input['file_path'] ?? input['filePath']) as string | undefined;

  if (FILE_READ_TOOLS.has(toolName) && filePath) {
    const uri = vscode.Uri.file(path.resolve(filePath));
    await vscode.window.showTextDocument(uri, { preview: true, preserveFocus: true });
    return;
  }

  if (FILE_WRITE_TOOLS.has(toolName) && filePath) {
    // Open current file for inspection; diff is shown via WorkspaceEdit after approval
    try {
      const uri = vscode.Uri.file(path.resolve(filePath));
      await vscode.window.showTextDocument(uri, { preview: true, preserveFocus: true });
    } catch {
      // File may not exist yet (create_file) — skip
    }

    // For write_file with new_content, stage a preview diff in the editor
    const newContent = input['new_content'] ?? input['content'];
    if (typeof newContent === 'string' && filePath) {
      const uri = vscode.Uri.file(path.resolve(filePath));
      const edit = new vscode.WorkspaceEdit();
      try {
        const doc = await vscode.workspace.openTextDocument(uri);
        edit.replace(uri, new vscode.Range(0, 0, doc.lineCount, 0), newContent);
        // Show diff — VS Code auto-shows the diff when an edit is applied to a visible doc
        await vscode.workspace.applyEdit(edit);
        vscode.commands.executeCommand('workbench.files.action.compareWithSaved');
      } catch { /* new file — nothing to diff */ }
    }
    return;
  }

  if (TERMINAL_TOOLS.has(toolName)) {
    const cmd = (input['command'] ?? input['cmd'] ?? input['script']) as string | undefined;
    if (cmd) {
      // Show what would run in a read-only terminal-like output (no execution)
      const terminal = vscode.window.createTerminal({
        name: `Chump preview: ${toolName}`,
        isTransient: true,
      });
      terminal.sendText(`# Pending approval for: ${toolName}`, false);
      terminal.sendText('', false);
      terminal.sendText(`# Command: ${cmd}`, false);
      terminal.show(true);
    }
    return;
  }
}

/** One-line human-readable summary of the tool invocation for the quickpick placeholder. */
function summariseInput(toolName: string, input: Record<string, unknown>): string {
  const filePath = input['path'] ?? input['file_path'] ?? input['filePath'];
  if (filePath) { return `${toolName}("${filePath}")`; }
  const cmd = input['command'] ?? input['cmd'];
  if (cmd) { return `${toolName}(${String(cmd).slice(0, 60)})`; }
  const keys = Object.keys(input);
  if (keys.length === 0) { return toolName; }
  return `${toolName}(${keys.slice(0, 3).join(', ')})`;
}
