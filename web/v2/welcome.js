// INFRA-1585: chump-welcome removed. Canonical first-run surface is
// <chump-first-run-wizard> (PRODUCT-108, app.js). This stub remains so any
// external script tags referencing welcome.js get a no-op module rather
// than a 404.
//
// localStorage migration: if the legacy chump_first_visit key is present we
// mark firstrun.dismissed=true so users who already completed the old flow
// are not shown the new wizard.
//
// Key mapping (executed once on import, before any component mounts):
//   chump_first_visit (any truthy value) → chumpPrefs firstrun.dismissed = true
//   chump_first_visit_completed          → same

(function migrateLegacyWelcomeKeys() {
  if (localStorage.getItem('chump_first_visit') || localStorage.getItem('chump_first_visit_completed')) {
    // chumpPrefs may not be loaded yet; write directly to localStorage using the
    // same key format that prefs.js uses (namespace prefix "chump.").
    if (!localStorage.getItem('chump.firstrun.dismissed')) {
      localStorage.setItem('chump.firstrun.dismissed', 'true');
    }
    // Leave the legacy keys in place for now (non-destructive migration).
  }
})();

// No custom element registered — <chump-welcome> is no longer in index.html.
