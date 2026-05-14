// PRODUCT-098 — PWA localStorage-backed user preferences
//
// Thin singleton wrapper that namespaces all keys under "chump.prefs.*",
// migrates the legacy parallelism-limit key, and dispatches a CustomEvent
// whenever a preference changes.
//
// Usage:
//   import { prefs } from './prefs.js';   // if module context
//   window.chumpPrefs.get('last-view', 'chat')
//   window.chumpPrefs.set('last-view', 'agents')
//
// Events dispatched on document:
//   CustomEvent('chump:pref-changed', { detail: { key, value, oldValue } })
//
// Ambient telemetry:
//   Best-effort POST to /api/ambient/emit with kind=pwa_prefs_changed.
//   Fails silently if server is unavailable or endpoint doesn't exist.

const NAMESPACE = 'chump.prefs.';

// Keys that existed before PRODUCT-098 under bare names → migrate to namespaced.
const LEGACY_MIGRATION = {
  'parallelism-limit': 'parallelism-limit',
};

class ChumpPrefs {
  // ── Core API ─────────────────────────────────────────────────────────────────

  /**
   * Get a preference value.
   * @param {string} key  — bare key (no namespace prefix)
   * @param {*} defaultValue
   * @returns {*} parsed JSON value, or defaultValue if unset/parse-error
   */
  get(key, defaultValue = null) {
    const storageKey = NAMESPACE + key;
    try {
      let raw = localStorage.getItem(storageKey);

      // Migration: if not found under namespaced key, check legacy bare key.
      if (raw === null && LEGACY_MIGRATION[key]) {
        raw = localStorage.getItem(LEGACY_MIGRATION[key]);
        if (raw !== null) {
          // Promote to namespaced key; leave legacy in place for one release.
          localStorage.setItem(storageKey, raw);
        }
      }

      if (raw === null) return defaultValue;
      try { return JSON.parse(raw); } catch { return raw; } // fallback: string
    } catch {
      return defaultValue;
    }
  }

  /**
   * Set a preference value.
   * @param {string} key  — bare key (no namespace prefix)
   * @param {*} value     — will be JSON-serialised
   */
  set(key, value) {
    const storageKey = NAMESPACE + key;
    let oldValue = null;
    try { oldValue = this.get(key); } catch {}

    try {
      const serialised = JSON.stringify(value);
      localStorage.setItem(storageKey, serialised);

      // Dispatch in-page event for reactive components.
      document.dispatchEvent(new CustomEvent('chump:pref-changed', {
        detail: { key, value, oldValue },
      }));

      // Best-effort ambient telemetry.
      this.#emitAmbient(key, value);
    } catch (e) {
      // localStorage may be unavailable (private browsing, storage full, etc.)
      // Fail silently — preferences are best-effort.
    }
  }

  /**
   * Remove a preference (reset to default).
   */
  remove(key) {
    const storageKey = NAMESPACE + key;
    try {
      localStorage.removeItem(storageKey);
      document.dispatchEvent(new CustomEvent('chump:pref-changed', {
        detail: { key, value: null, oldValue: this.get(key) },
      }));
    } catch {}
  }

  /**
   * Return all stored preference keys (bare, without namespace prefix).
   */
  keys() {
    try {
      const result = [];
      for (let i = 0; i < localStorage.length; i++) {
        const k = localStorage.key(i);
        if (k && k.startsWith(NAMESPACE)) {
          result.push(k.slice(NAMESPACE.length));
        }
      }
      return result;
    } catch { return []; }
  }

  // ── Ambient telemetry ─────────────────────────────────────────────────────

  #emitAmbient(key, value) {
    // Best-effort: POST to /api/ambient/emit if the endpoint exists.
    // Fails silently — this is informational telemetry only.
    try {
      fetch('/api/ambient/emit', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          kind: 'pwa_prefs_changed',
          pref_key: key,
          // Redact values that might contain sensitive data.
          pref_value: typeof value === 'string' ? value.slice(0, 64) : value,
          ts: new Date().toISOString(),
        }),
      }).catch(() => {}); // swallow network/fetch errors
    } catch {}
  }
}

// Expose singleton.
const prefs = new ChumpPrefs();
window.chumpPrefs = prefs;
export { prefs };
