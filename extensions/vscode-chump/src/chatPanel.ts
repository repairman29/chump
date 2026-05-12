/**
 * chatPanel.ts — PRODUCT-057 slice 2
 *
 * WebviewViewProvider: chat sidebar panel with text input, message list,
 * incremental SSE-streamed agent responses, and minimal markdown rendering.
 *
 * Protocol:
 *   session/new   → {sessionId}
 *   session/prompt {sessionId, prompt:[{type:"text",text}]}  → PromptResponse
 *   notifications: session/update {sessionId, update:{type, content}}
 */

import * as vscode from 'vscode';
import { AcpClient } from './acpClient';

export class ChatPanel implements vscode.WebviewViewProvider {
  static readonly viewType = 'chump.chatView';

  private view?: vscode.WebviewView;
  private sessionId?: string;

  constructor(
    private readonly getClient: () => AcpClient | undefined,
  ) {}

  clear(): void {
    this.sessionId = undefined;
    this.view?.webview.postMessage({ type: 'clear' });
  }

  resolveWebviewView(
    webviewView: vscode.WebviewView,
    _context: vscode.WebviewViewResolveContext,
    _token: vscode.CancellationToken,
  ): void {
    this.view = webviewView;
    webviewView.webview.options = { enableScripts: true };
    webviewView.webview.html = this._buildHtml();

    webviewView.webview.onDidReceiveMessage(async (msg: { type: string; text?: string }) => {
      if (msg.type === 'send' && msg.text) {
        await this._handleUserMessage(msg.text);
      } else if (msg.type === 'clear') {
        this.sessionId = undefined;
        this.view?.webview.postMessage({ type: 'clear' });
      }
    });
  }

  private async _handleUserMessage(text: string): Promise<void> {
    const client = this.getClient();
    if (!client || client.status !== 'connected') {
      this.view?.webview.postMessage({ type: 'error', text: 'Not connected to Chump ACP backend.' });
      return;
    }

    this.view?.webview.postMessage({ type: 'user', text });

    if (!this.sessionId) {
      try {
        const res = await client.request('session/new', {}) as { sessionId: string };
        this.sessionId = res.sessionId;
      } catch (err) {
        this.view?.webview.postMessage({ type: 'error', text: `Failed to create session: ${(err as Error).message}` });
        return;
      }
    }

    this.view?.webview.postMessage({ type: 'assistant_start' });

    const sid = this.sessionId;
    const webview = this.view?.webview;

    const onNotification = (method: string, params: unknown): void => {
      if (method !== 'session/update') { return; }
      const p = params as { sessionId: string; update: { type: string; content?: string } };
      if (p.sessionId !== sid) { return; }
      const u = p.update;
      if (u.type === 'agent_message_delta' && u.content) {
        webview?.postMessage({ type: 'delta', text: u.content });
      } else if (u.type === 'agent_message_complete' && u.content) {
        webview?.postMessage({ type: 'complete', text: u.content });
      }
    };

    client.on('notification', onNotification);

    try {
      await client.request('session/prompt', {
        sessionId: sid,
        prompt: [{ type: 'text', text }],
      });
      this.view?.webview.postMessage({ type: 'assistant_done' });
    } catch (err) {
      this.view?.webview.postMessage({ type: 'error', text: `Prompt failed: ${(err as Error).message}` });
    } finally {
      client.off('notification', onNotification);
    }
  }

  private _buildHtml(): string {
    // NB: backtick escaped as \` inside the template literal below.
    // \\s, \\S, \\n, \\* produce literal \s \S \n \* in the emitted HTML/JS.
    return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"/>
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline';"/>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:var(--vscode-font-family);font-size:var(--vscode-font-size);color:var(--vscode-foreground);background:var(--vscode-sideBar-background);display:flex;flex-direction:column;height:100vh;overflow:hidden}
#msgs{flex:1;overflow-y:auto;padding:8px;display:flex;flex-direction:column;gap:6px}
.msg{padding:6px 10px;border-radius:4px;line-height:1.5;word-break:break-word}
.user{background:var(--vscode-button-background);color:var(--vscode-button-foreground);align-self:flex-end;max-width:85%}
.assistant{background:var(--vscode-editor-inactiveSelectionBackground);align-self:flex-start;max-width:100%}
.err{color:var(--vscode-inputValidation-errorForeground);font-style:italic}
.msg pre{background:var(--vscode-textBlockQuote-background);border-left:3px solid var(--vscode-activityBarBadge-background);padding:6px;margin:4px 0;overflow-x:auto;white-space:pre}
.msg code{background:var(--vscode-textBlockQuote-background);font-family:var(--vscode-editor-font-family);font-size:.9em;padding:1px 3px;border-radius:2px}
.msg pre code{background:none;padding:0}
.cursor{display:inline-block;width:2px;height:1em;background:currentColor;animation:blink 1s step-end infinite;vertical-align:text-bottom}
@keyframes blink{0%,100%{opacity:1}50%{opacity:0}}
#foot{padding:8px;border-top:1px solid var(--vscode-sideBarSectionHeader-border);display:flex;gap:4px}
#inp{flex:1;background:var(--vscode-input-background);color:var(--vscode-input-foreground);border:1px solid var(--vscode-input-border);padding:5px 8px;font-family:inherit;font-size:inherit;resize:none;border-radius:3px;outline:none;min-height:32px;max-height:100px}
#inp:focus{border-color:var(--vscode-focusBorder)}
#btn{background:var(--vscode-button-background);color:var(--vscode-button-foreground);border:none;padding:5px 10px;cursor:pointer;border-radius:3px;align-self:flex-end}
#btn:hover{background:var(--vscode-button-hoverBackground)}
#btn:disabled{opacity:.5;cursor:not-allowed}
</style>
</head>
<body>
<div id="msgs"></div>
<div id="foot">
  <textarea id="inp" placeholder="Ask Chump…" rows="1"></textarea>
  <button id="btn">Send</button>
</div>
<script>
(function(){
  const vsc=acquireVsCodeApi(), msgs=document.getElementById('msgs'),
        inp=document.getElementById('inp'), btn=document.getElementById('btn');
  let cur=null, acc='';

  function esc(s){return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');}
  function md(text){
    let s=esc(text);
    s=s.replace(/\`\`\`([\\s\\S]*?)\`\`\`/g,(_,c)=>'<pre><code>'+c.replace(/^\\n/,'')+'</code></pre>');
    s=s.replace(/\`([^\`\\n]+)\`/g,'<code>$1</code>');
    s=s.replace(/\\*\\*([^*\\n]+)\\*\\*/g,'<strong>$1</strong>');
    s=s.replace(/\\*([^*\\n]+)\\*/g,'<em>$1</em>');
    s=s.replace(/\\[([^\\]]+)\\]\\(([^)]+)\\)/g,'<a href="$2">$1</a>');
    s=s.replace(/\\n/g,'<br>');
    return s;
  }
  function addMsg(cls,html){
    const el=document.createElement('div');
    el.className='msg '+cls; el.innerHTML=html;
    msgs.appendChild(el); msgs.scrollTop=msgs.scrollHeight;
    return el;
  }
  function send(){
    const t=inp.value.trim(); if(!t||btn.disabled)return;
    inp.value=''; inp.style.height=''; btn.disabled=true;
    vsc.postMessage({type:'send',text:t});
  }
  btn.addEventListener('click',send);
  inp.addEventListener('keydown',e=>{if(e.key==='Enter'&&!e.shiftKey){e.preventDefault();send();}});
  inp.addEventListener('input',()=>{inp.style.height='auto';inp.style.height=Math.min(inp.scrollHeight,100)+'px';});
  window.addEventListener('message',e=>{
    const m=e.data;
    switch(m.type){
      case 'user': acc=''; cur=null; addMsg('user',md(m.text)); break;
      case 'assistant_start': acc=''; cur=addMsg('assistant','<span class="cursor"></span>'); break;
      case 'delta':
        if(cur){acc+=m.text; cur.innerHTML=md(acc)+'<span class="cursor"></span>'; msgs.scrollTop=msgs.scrollHeight;}
        break;
      case 'complete':
        if(cur){acc=m.text; cur.innerHTML=md(m.text);}
        break;
      case 'assistant_done':
        if(cur){const c=cur.querySelector('.cursor'); if(c)c.remove(); cur=null;}
        btn.disabled=false; break;
      case 'error': addMsg('msg err',md(m.text)); btn.disabled=false; cur=null; break;
      case 'clear': msgs.innerHTML=''; cur=null; acc=''; break;
    }
  });
})();
</script>
</body>
</html>`;
  }
}
