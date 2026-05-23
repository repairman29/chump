// approval.js — INFRA-1340 (PRODUCT-109 follow-up)
//
// Augments <chump-tool-approval-tray> (defined in app.js) with a per-tool
// auto-approve POLICY DROPDOWN. Operator picks 15min / 1h / session for the
// tool referenced by an approval row; the choice is POSTed to /api/tool-policy
// and persisted server-side in .chump/tool-policies.json. Subsequent calls to
// the same tool fire automatically until the TTL elapses.
//
// Independent of the audio cue and Web Push escalation — those are server-side
// gated by CHUMP_APPROVAL_AUDIO and CHUMP_APPROVAL_ESCALATION env vars.
//
// Wiring:
//   - Listens for the 'chump:tool_approval' CustomEvent dispatched by chat.js,
//     just like the tray itself; uses MutationObserver to inject the dropdown
//     into each tat-row after the tray renders.
//   - Click on dropdown option → POST /api/tool-policy {tool_name, scope}.
//   - Stores last-known active policies in localStorage as a UI hint; server
//     remains source of truth.

const POLICY_API = '/api/tool-policy';
const SCOPES = [
  { key: '15min', label: '15 min', ttl: 900 },
  { key: '1h', label: '1 hour', ttl: 3600 },
  { key: 'session', label: 'session', ttl: 7 * 24 * 3600 },
];

// ── helpers ────────────────────────────────────────────────────────────────
function esc(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  }[c]));
}

async function postPolicy(toolName, scope) {
  const body = { tool_name: toolName, scope };
  const r = await fetch(POLICY_API, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  if (!r.ok) throw new Error(`policy upsert HTTP ${r.status}`);
  return r.json();
}

async function deletePolicy(toolName) {
  const r = await fetch(`${POLICY_API}/${encodeURIComponent(toolName)}`, {
    method: 'DELETE',
  });
  if (!r.ok) throw new Error(`policy delete HTTP ${r.status}`);
  return r.json();
}

async function listPolicies() {
  try {
    const r = await fetch(POLICY_API);
    if (!r.ok) return [];
    const d = await r.json();
    return Array.isArray(d.policies) ? d.policies : [];
  } catch {
    return [];
  }
}

// Inject dropdown into one tray row. Idempotent — checks for an existing
// .tat-policy-dropdown before adding.
function decorateRow(row, knownPolicies) {
  if (!row || row.querySelector('.tat-policy-dropdown')) return;
  const toolName = row.querySelector('.tat-tool')?.textContent?.trim();
  if (!toolName) return;

  const actions = row.querySelector('.tat-actions');
  if (!actions) return;

  const existing = knownPolicies.find(
    (p) => String(p.tool_name).toLowerCase() === toolName.toLowerCase(),
  );

  const wrap = document.createElement('div');
  wrap.className = 'tat-policy-dropdown';
  wrap.dataset.tool = toolName;
  wrap.setAttribute('role', 'group');
  wrap.setAttribute('aria-label', `Auto-approve ${toolName} for…`);
  wrap.innerHTML = `
    <label class="tat-policy-label" title="Auto-approve future ${esc(toolName)} calls">
      auto-approve:
    </label>
    <select class="tat-policy-select" aria-label="Auto-approve ${esc(toolName)} for…">
      <option value="" ${existing ? '' : 'selected'}>off (ask each time)</option>
      ${SCOPES.map(
        (s) =>
          `<option value="${s.key}" ${
            existing && String(existing.scope).toLowerCase() === s.key ? 'selected' : ''
          }>${s.label}</option>`,
      ).join('')}
    </select>
    <span class="tat-policy-status" aria-live="polite"></span>
  `;
  actions.appendChild(wrap);

  const select = wrap.querySelector('.tat-policy-select');
  const status = wrap.querySelector('.tat-policy-status');
  select?.addEventListener('change', async (e) => {
    const val = e.target.value;
    status.textContent = '…';
    try {
      if (!val) {
        await deletePolicy(toolName);
        status.textContent = 'cleared';
        emitTelemetry({ action: 'cleared', tool: toolName });
      } else {
        await postPolicy(toolName, val);
        status.textContent = `auto for ${val}`;
        emitTelemetry({ action: 'set', tool: toolName, scope: val });
      }
    } catch (err) {
      status.textContent = `failed: ${err.message}`;
      status.classList.add('tat-policy-status-error');
    }
  });
}

function emitTelemetry(fields) {
  try {
    navigator.sendBeacon?.(
      '/api/ambient/emit',
      JSON.stringify({
        kind: 'tool_approval_policy_ui',
        ts: new Date().toISOString(),
        ...fields,
      }),
    );
  } catch {}
}

// ── boot ───────────────────────────────────────────────────────────────────
async function bootApprovalDropdown() {
  // Wait for the tray to register; app.js defines it, so the custom element
  // should be present shortly after DOMContentLoaded.
  await customElements.whenDefined?.('chump-tool-approval-tray').catch(() => {});

  const tray = document.querySelector('chump-tool-approval-tray');
  if (!tray) return; // not on a view that mounts the tray (e.g. minimal index)

  let policies = await listPolicies();

  // Decorate any rows already present.
  const decorateAll = () => {
    tray.querySelectorAll('.tat-row').forEach((r) => decorateRow(r, policies));
  };
  decorateAll();

  // Watch for new rows added by the tray's #render().
  const list = tray.querySelector('#tat-list') || tray;
  const observer = new MutationObserver(() => decorateAll());
  observer.observe(list, { childList: true, subtree: true });

  // Re-sync policy list every 30s — TTLs may have expired server-side.
  setInterval(async () => {
    policies = await listPolicies();
    // Drop stale dropdowns + redraw against new state.
    tray.querySelectorAll('.tat-policy-dropdown').forEach((d) => d.remove());
    decorateAll();
  }, 30_000);
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', bootApprovalDropdown, { once: true });
} else {
  bootApprovalDropdown();
}

// Exported for direct unit tests / debugging.
export { postPolicy, deletePolicy, listPolicies, decorateRow, SCOPES };
