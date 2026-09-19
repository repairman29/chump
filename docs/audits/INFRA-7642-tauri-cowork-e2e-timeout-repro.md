# `tauri-cowork-e2e` Selenium timeout — reproduction attempt (INFRA-1433 slice)

> **Gap:** INFRA-7642 (INFRA-1433 slice)
> **Scope:** run the `tauri-cowork-e2e` test, observe the 60s timeout on the
> `chump-chat` selector, capture console + Selenium logs showing the failure.

## Result: does not reproduce as of 2026-09-19 — fix already landed (INFRA-7412)

The specific failure this gap asks to reproduce — a wait timeout on the
`chump-chat` CSS selector — was root-caused by
[`INFRA-6338`](./INFRA-6338-chump-chat-selector-investigation.md) and fixed by
[`INFRA-7412`](./INFRA-7412-chump-chat-selector-investigation.md)
(`4742b6064`, merged 2026-09-18T19:44Z), which made `e2e-tauri/run.mjs` click
`[data-view="chat"]` before waiting on `<chump-chat>`.

**Local reproduction was not attempted end-to-end**: this environment lacks
`WebKitWebDriver` and `tauri-driver` (both required by `e2e-tauri/run.mjs`'s
prereq comment) and has no pre-built `target/debug/chump-desktop` /
`target/debug/chump` binaries, so a from-scratch local run would mean a full
Tauri desktop build plus installing WebDriver tooling — far outside this
gap's `s` effort budget. As with the two prior INFRA-1433 slices
(INFRA-7412, INFRA-6338), CI's `ci-nightly.yml` → `tauri-cowork-e2e` job is
used as the reproduction environment instead, since it runs the identical
`xvfb-run … node e2e-tauri/run.mjs` invocation this gap is asking about.

### Evidence — pre-fix run reproduces the timeout

`ci-nightly.yml` run [`35316301882`](https://github.com) (2026-09-18T06:47Z,
before the fix landed at 19:44Z the same day), job `tauri-cowork-e2e`:

```
tauri e2e: #app-title found at t=1789714447889; waiting for <chump-chat>…
              reject(new error.TimeoutError(`${timeoutMessage}Wait timed out after ${elapsed}ms`))
TimeoutError: Waiting for element to be located By(css selector, chump-chat)
##[error]Process completed with exit code 1.
```

No other console/app errors precede it — `#app-title` (light-DOM, always
rendered) locates quickly, then the wait on `chump-chat` times out with no
JS exception, consistent with INFRA-6338's root cause: the element simply
never mounts because the test never opens the Chat sub-tab.

The three runs immediately preceding the fix (`35316301882`, `35191579482`,
`35065911742`, `34938768906` — 2026-09-15 through 2026-09-18) all fail with
this identical signature.

### Evidence — post-fix run no longer times out

`ci-nightly.yml` run `35427481372` (2026-09-19T06:45Z, first nightly run
after the fix merged), job `tauri-cowork-e2e`, **conclusion: success**:

```
tauri e2e: #app-title found at t=1789800834177; clicking Chat nav…
tauri e2e: Chat nav clicked at t=1789800834239; waiting for <chump-chat>…
tauri e2e: <chump-chat> located at t=1789800834286; waiting for shadow root…
tauri webdriver e2e: ok (page-load + chump-chat upgrade verified; INFRA-263 will restore /task round-trip)
```

`<chump-chat>` now locates in ~47 ms after the Chat nav click (vs. the prior
120 s timeout) — the fix holds.

## Conclusion

The 60s/120s `chump-chat` timeout this gap asks to reproduce is a **fixed
bug**, not a currently-reproducible condition: INFRA-7412 landed the fix the
day before this gap was worked, and the very next nightly CI run confirms
it. Filing further "reproduce this" slices against INFRA-1433 is no longer
useful — the open question was already answered and the fix verified in
production CI. Closing this slice as **resolved / superseded by INFRA-7412**.

## Related prior work

- [`docs/audits/INFRA-6338-chump-chat-selector-investigation.md`](./INFRA-6338-chump-chat-selector-investigation.md) — original root-cause.
- [`docs/audits/INFRA-7154-chump-chat-selector-investigation.md`](./INFRA-7154-chump-chat-selector-investigation.md) — second slice, confirmed same facts.
- [`docs/audits/INFRA-7412-chump-chat-selector-investigation.md`](./INFRA-7412-chump-chat-selector-investigation.md) — fix landed here (`e2e-tauri/run.mjs` clicks Chat nav before waiting).
- `docs/gaps/INFRA-1433.yaml` — parent gap, full original AC.
