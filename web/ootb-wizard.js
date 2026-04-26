/**
 * First-run OOTB wizard (Tauri / Cowork shell only).
 * See docs/PACKAGED_OOTB_DESKTOP.md
 */
(function chumpOotbWizard() {
  var DEFAULT_OLLAMA_BASE = 'http://127.0.0.1:11434/v1';

  var STEP_HEADINGS = [
    '',
    'Welcome to Chump',
    'Connect your LLM',
    'Your data & model',
    'Pull the model',
    'Start the engine',
  ];

  function isTauriHost() {
    try {
      var h = location.hostname;
      return h === 'tauri.localhost' || (typeof h === 'string' && h.endsWith('.tauri.localhost'));
    } catch (_) {
      return false;
    }
  }

  function tauriInvoke(cmd, args) {
    try {
      var w = window.__TAURI__;
      if (!w) return null;
      if (w.core && typeof w.core.invoke === 'function') {
        return args === undefined ? w.core.invoke(cmd) : w.core.invoke(cmd, args);
      }
      if (typeof w.invoke === 'function') {
        return args === undefined ? w.invoke(cmd) : w.invoke(cmd, args);
      }
    } catch (_) {}
    return null;
  }

  function getTauriListen() {
    var w = window.__TAURI__;
    if (!w) return null;
    if (w.event && typeof w.event.listen === 'function') return w.event.listen.bind(w.event);
    if (w.core && w.core.event && typeof w.core.event.listen === 'function') {
      return w.core.event.listen.bind(w.core.event);
    }
    return null;
  }

  function $(id) {
    return document.getElementById(id);
  }

  function setShellInert(on) {
    var gate = document.getElementById('desktop-gate');
    var wrap = document.getElementById('app-wrap');
    try {
      if (gate) gate.inert = !!on;
      if (wrap) wrap.inert = !!on;
    } catch (_) {}
  }

  function setWindowTitleForWizard(active) {
    var p = tauriInvoke('set_main_window_title', {
      title: active ? 'Chump · First-time setup' : 'Chump · Cowork',
    });
    if (p && p.then) p.catch(function () {});
  }

  function show(el, on) {
    if (!el) return;
    el.classList.toggle('visible', !!on);
    el.setAttribute('aria-hidden', on ? 'false' : 'true');
  }

  function setStatus(msg, tone) {
    var s = $('ootb-status');
    if (!s) return;
    s.textContent = msg || '';
    s.setAttribute('aria-live', tone === 'err' ? 'assertive' : 'polite');
    s.classList.remove('ootb-status--ok', 'ootb-status--err', 'ootb-status--busy');
    if (tone === 'ok') s.classList.add('ootb-status--ok');
    else if (tone === 'err') s.classList.add('ootb-status--err');
    else if (tone === 'busy') s.classList.add('ootb-status--busy');
  }

  function apiBaseTrimmed() {
    var inp = $('ootb-api-base');
    return inp ? inp.value.trim() : '';
  }

  function usesOllamaModelPull(skipOllamaPath, baseInput) {
    if (skipOllamaPath) return false;
    var b = (baseInput || '').trim();
    if (!b) return true;
    var n = b.replace(/\/+$/, '').toLowerCase();
    var d = DEFAULT_OLLAMA_BASE.replace(/\/+$/, '').toLowerCase();
    if (n === d) return true;
    return /:(11434)(\b|\/)/.test(n);
  }

  function updateProgressDots(currentStep) {
    for (var i = 1; i <= 5; i++) {
      var d = document.querySelector('[data-ootb-dot="' + i + '"]');
      if (!d) continue;
      d.classList.remove('active', 'done');
      if (i < currentStep) d.classList.add('done');
      else if (i === currentStep) d.classList.add('active');
    }
  }

  function updateStepHeading(n) {
    var h = $('ootb-step-heading');
    if (h && STEP_HEADINGS[n]) h.textContent = STEP_HEADINGS[n];
  }

  function updateRevealRow(n, state) {
    var row = $('ootb-reveal-row');
    if (!row) return;
    row.style.display = state.userDataPath && n >= 4 && n <= 5 ? 'block' : 'none';
  }

  function setStep(n, state, root) {
    for (var i = 1; i <= 5; i++) {
      var p = $('ootb-step-' + i);
      if (p) p.style.display = i === n ? 'block' : 'none';
    }
    var hint = $('ootb-step-hint');
    if (hint) hint.textContent = 'Step ' + n + ' of 5';
    updateProgressDots(n);
    updateStepHeading(n);
    updateRevealRow(n, state);

    if (n === 4 && state) {
      var oll = $('ootb-step-4-ollama');
      var no = $('ootb-step-4-no-ollama');
      var pull = usesOllamaModelPull(state.skipOllamaPath, state.apiBaseSnapshot);
      if (oll) oll.style.display = pull ? 'block' : 'none';
      if (no) no.style.display = pull ? 'none' : 'block';
      if (pull) {
        var log = $('ootb-pull-log');
        if (log && !log.textContent) log.textContent = '';
      }
    }

    if (n !== 5) {
      var rb = $('ootb-retry-engine');
      if (rb) rb.style.display = 'none';
    }

    if (n === 3) void refreshPathPreview();

    if (root && root.classList.contains('visible')) focusStepPrimary(n, state);
  }

  function focusStepPrimary(step, state) {
    requestAnimationFrame(function () {
      var skipC = $('ootb-skip-confirm');
      if (skipC && skipC.style.display !== 'none') {
        var c = $('ootb-skip-cancel');
        if (c) c.focus();
        return;
      }
      var id = null;
      if (step === 1) id = 'ootb-next-1';
      else if (step === 2) id = 'ootb-next-2';
      else if (step === 3) id = 'ootb-create-config';
      else if (step === 4) {
        id = usesOllamaModelPull(state.skipOllamaPath, state.apiBaseSnapshot) ? 'ootb-pull' : 'ootb-nonollama-next';
      } else if (step === 5) {
        var retry = $('ootb-retry-engine');
        id = retry && retry.style.display !== 'none' ? 'ootb-retry-engine' : 'ootb-start-chump';
      }
      var el = id ? $(id) : null;
      if (el && typeof el.focus === 'function') el.focus();
    });
  }

  function getWizardFocusables(root) {
    if (!root) return [];
    var ov = $('ootb-success-overlay');
    if (ov && ov.classList.contains('visible')) return [];
    var sel =
      'a[href]:not([disabled]), button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';
    var all = root.querySelectorAll(sel);
    var out = [];
    var skipC = $('ootb-skip-confirm');
    var skipVisible = skipC && skipC.style.display !== 'none';
    for (var i = 0; i < all.length; i++) {
      var el = all[i];
      var st0 = window.getComputedStyle(el);
      if (st0.visibility === 'hidden' || st0.display === 'none') continue;
      if (el.offsetParent === null && st0.position !== 'fixed' && st0.position !== 'sticky') continue;
      var stepHost = el.closest('[id^="ootb-step-"]');
      if (stepHost && stepHost.style.display === 'none') continue;
      if (skipVisible) {
        if (el.closest('#ootb-step-1-main')) continue;
      } else {
        if (el.closest('#ootb-skip-confirm')) continue;
      }
      var rr = $('ootb-reveal-row');
      if (rr && rr.style.display === 'none' && el.id === 'ootb-reveal-folder') continue;
      out.push(el);
    }
    return out;
  }

  function friendlyEngineReason(reason) {
    var fallback =
      'The engine did not become ready. If you use a release .app, the chump binary must sit next to the desktop executable inside the bundle.';
    if (!reason) return fallback;
    var r = String(reason);
    if (r.indexOf('chump_binary_not_found_next_to_desktop') !== -1) {
      return 'The Chump engine was not found beside this app. From source: build both chump and chump-desktop; for a .app, run scripts/setup/macos-cowork-dock-app.sh so chump is copied into Contents/MacOS/.';
    }
    if (r.indexOf('spawn_failed') !== -1) {
      return 'Could not start the engine: ' + r.replace(/^spawn_failed:\s*/i, '');
    }
    if (r.indexOf('health_still_unreachable_after_wait') !== -1) {
      return 'The process started but /api/health did not respond in time. Check nothing else uses the same port, then try again.';
    }
    return r;
  }

  function friendlyPullError(msg) {
    var s = String(msg);
    if (/spawn ollama/i.test(s) || /No such file|ENOENT/i.test(s)) {
      return 'Could not run ollama — install it and ensure it is on your PATH, then try again.';
    }
    return s;
  }

  async function refreshPathPreview() {
    var el = $('ootb-path-preview');
    if (!el) return;
    try {
      var p = await tauriInvoke('ootb_user_data_dir_path');
      if (p) el.textContent = 'Config and chats will live under: ' + p;
    } catch (_) {
      el.textContent = '';
    }
  }

  async function waitForIpc() {
    var deadline = Date.now() + 10000;
    while (Date.now() < deadline) {
      var p = tauriInvoke('ootb_wizard_should_show');
      if (p && typeof p.then === 'function') return true;
      await new Promise(function (r) {
        setTimeout(r, 40);
      });
    }
    return false;
  }

  var pullUnlisten = null;
  var pullBuf = [];
  var pullRaf = null;

  async function subscribePullLog(onLine) {
    var listen = getTauriListen();
    if (!listen) return;
    try {
      pullUnlisten = await listen('ootb-pull-line', function (e) {
        var payload = e && e.payload;
        var line =
          payload && typeof payload === 'object' && payload.line != null
            ? String(payload.line)
            : payload != null
              ? String(payload)
              : '';
        if (line) onLine(line);
      });
    } catch (_) {
      pullUnlisten = null;
    }
  }

  function unsubscribePullLog() {
    if (typeof pullUnlisten === 'function') {
      try {
        pullUnlisten();
      } catch (_) {}
    }
    pullUnlisten = null;
  }

  function flushPullBuf() {
    pullRaf = null;
    var log = $('ootb-pull-log');
    if (!log || pullBuf.length === 0) return;
    var chunk = pullBuf.join('\n');
    pullBuf = [];
    var t = log.textContent;
    if (t.length > 24000) t = t.slice(-20000);
    log.textContent = t ? t + '\n' + chunk : chunk;
    log.scrollTop = log.scrollHeight;
  }

  function appendPullLog(line) {
    pullBuf.push(line);
    if (!pullRaf) pullRaf = requestAnimationFrame(flushPullBuf);
  }

  function clearPullLog() {
    pullBuf = [];
    if (pullRaf) {
      cancelAnimationFrame(pullRaf);
      pullRaf = null;
    }
    var log = $('ootb-pull-log');
    if (log) log.textContent = '';
  }

  async function main() {
    if (!isTauriHost()) return;
    if (localStorage.getItem('chump_ootb_dismissed') === '1') return;
    var ready = await waitForIpc();
    if (!ready) return;
    var should;
    try {
      should = await tauriInvoke('ootb_wizard_should_show');
    } catch (_) {
      return;
    }
    if (!should) return;

    var root = $('ootb-wizard');
    if (!root) return;
    show(root, true);
    setShellInert(true);
    setWindowTitleForWizard(true);

    var state = {
      skipOllamaPath: false,
      apiBaseSnapshot: '',
      userDataPath: '',
    };

    var step = 1;
    setStep(step, state, root);
    var selectedModel = 'qwen2.5:7b';
    try {
      var d = await tauriInvoke('ootb_default_model');
      if (d && typeof d === 'string') selectedModel = d;
    } catch (_) {}

    var sel = $('ootb-model-select');
    if (sel) {
      sel.value = selectedModel;
      sel.addEventListener('change', function () {
        selectedModel = sel.value;
      });
    }

    function showSkipConfirm(show) {
      var main = $('ootb-step-1-main');
      var conf = $('ootb-skip-confirm');
      if (main) main.style.display = show ? 'none' : 'block';
      if (conf) conf.style.display = show ? 'block' : 'none';
      if (show) $('ootb-skip-cancel') && $('ootb-skip-cancel').focus();
      else focusStepPrimary(1, state);
    }

    root.addEventListener(
      'keydown',
      function (ev) {
        if (ev.key === 'Tab' && root.classList.contains('visible')) {
          var ov = $('ootb-success-overlay');
          if (ov && ov.classList.contains('visible')) return;
          var list = getWizardFocusables(root);
          if (list.length === 0) return;
          var first = list[0];
          var last = list[list.length - 1];
          if (ev.shiftKey) {
            if (document.activeElement === first) {
              ev.preventDefault();
              last.focus();
            }
          } else {
            if (document.activeElement === last) {
              ev.preventDefault();
              first.focus();
            }
          }
        }
        if (ev.key !== 'Escape' || ev.defaultPrevented) return;
        var conf = $('ootb-skip-confirm');
        if (conf && conf.style.display !== 'none') {
          ev.preventDefault();
          showSkipConfirm(false);
          return;
        }
        if (step <= 1) return;
        ev.preventDefault();
        if (step === 2 && $('ootb-back-2')) $('ootb-back-2').click();
        else if (step === 3 && $('ootb-back-3')) $('ootb-back-3').click();
        else if (step === 4 && $('ootb-back-4')) $('ootb-back-4').click();
        else if (step === 5 && $('ootb-back-5')) $('ootb-back-5').click();
      },
      true
    );

    $('ootb-reveal-folder') &&
      $('ootb-reveal-folder').addEventListener('click', function () {
        var p = tauriInvoke('ootb_reveal_user_data_folder');
        if (p && p.then) p.catch(function (e) { setStatus(String(e), 'err'); });
      });

    $('ootb-copy-pull-log') &&
      $('ootb-copy-pull-log').addEventListener('click', function () {
        var log = $('ootb-pull-log');
        if (!log || !log.textContent) {
          setStatus('Nothing to copy yet.', 'busy');
          return;
        }
        navigator.clipboard.writeText(log.textContent).then(
          function () {
            setStatus('Log copied to clipboard.', 'ok');
          },
          function () {
            setStatus('Could not copy — select the log and copy manually.', 'err');
          }
        );
      });

    $('ootb-next-1') &&
      $('ootb-next-1').addEventListener('click', function () {
        step = 2;
        setStep(step, state, root);
        void refreshOllama();
      });

    async function refreshOllama() {
      setStatus('Checking Ollama…', 'busy');
      try {
        var j = await tauriInvoke('ootb_detect_ollama');
        if (j && j.installed) {
          setStatus('Ollama is ready — ' + (j.version || 'installed').replace(/\s+/g, ' ').trim(), 'ok');
        } else {
          setStatus(
            'Ollama was not found on PATH. Use “Open Ollama download”, or choose “LM Studio / MLX…” if you use another server.',
            'err'
          );
        }
      } catch (e) {
        setStatus(String(e), 'err');
      }
    }

    $('ootb-check-ollama') &&
      $('ootb-check-ollama').addEventListener('click', function () {
        void refreshOllama();
      });
    $('ootb-open-download') &&
      $('ootb-open-download').addEventListener('click', function () {
        var p = tauriInvoke('ootb_open_ollama_download');
        if (p && p.then) p.catch(function () {});
      });

    $('ootb-skip-wizard') &&
      $('ootb-skip-wizard').addEventListener('click', function () {
        showSkipConfirm(true);
      });

    $('ootb-skip-cancel') &&
      $('ootb-skip-cancel').addEventListener('click', function () {
        showSkipConfirm(false);
      });

    $('ootb-skip-confirm-btn') &&
      $('ootb-skip-confirm-btn').addEventListener('click', function () {
        localStorage.setItem('chump_ootb_dismissed', '1');
        setShellInert(false);
        setWindowTitleForWizard(false);
        show(root, false);
        window.dispatchEvent(new Event('chump-ootb-finished'));
        setTimeout(function () {
          window.dispatchEvent(new Event('chump-api-root-ready'));
        }, 100);
      });

    $('ootb-skip-ollama-path') &&
      $('ootb-skip-ollama-path').addEventListener('click', function () {
        state.skipOllamaPath = true;
        step = 3;
        setStep(step, state, root);
        setStatus('Open “Advanced” and paste your API base URL, then create config.', 'busy');
      });

    $('ootb-next-2') &&
      $('ootb-next-2').addEventListener('click', async function () {
        try {
          var j = await tauriInvoke('ootb_detect_ollama');
          if (!j || !j.installed) {
            setStatus('Install Ollama first, or use “LM Studio / MLX…” if you are not using Ollama.', 'err');
            return;
          }
        } catch (e) {
          setStatus(String(e), 'err');
          return;
        }
        state.skipOllamaPath = false;
        step = 3;
        setStep(step, state, root);
        setStatus('');
      });

    $('ootb-back-2') &&
      $('ootb-back-2').addEventListener('click', function () {
        step = 1;
        state.skipOllamaPath = false;
        setStep(step, state, root);
        setStatus('');
      });

    $('ootb-create-config') &&
      $('ootb-create-config').addEventListener('click', async function () {
        var baseInput = apiBaseTrimmed();
        if (state.skipOllamaPath && !baseInput) {
          setStatus('Enter your API base URL under Advanced (or go back and use the Ollama path).', 'err');
          var det = $('ootb-advanced-details');
          if (det) det.open = true;
          $('ootb-api-base') && $('ootb-api-base').focus();
          return;
        }
        setStatus('Writing your config…', 'busy');
        try {
          var payload = { model: selectedModel };
          if (baseInput) payload.openaiApiBase = baseInput;
          var path = await tauriInvoke('ootb_prepare_user_data', payload);
          state.apiBaseSnapshot = baseInput;
          state.userDataPath = path;
          setStatus('Saved — ' + path, 'ok');
          step = 4;
          setStep(step, state, root);
        } catch (e) {
          setStatus(String(e), 'err');
        }
      });

    $('ootb-back-3') &&
      $('ootb-back-3').addEventListener('click', function () {
        step = 2;
        setStep(step, state, root);
        setStatus('');
        void refreshOllama();
      });

    $('ootb-pull') &&
      $('ootb-pull').addEventListener('click', async function () {
        clearPullLog();
        setStatus('Downloading — output streams below. Large models can take several minutes.', 'busy');
        var btn = $('ootb-pull');
        if (btn) btn.disabled = true;
        await subscribePullLog(appendPullLog);
        try {
          var summary = await tauriInvoke('ootb_pull_model', { model: selectedModel });
          if (summary) appendPullLog(typeof summary === 'string' ? summary : String(summary));
          flushPullBuf();
          var okModel = await tauriInvoke('ootb_model_present', { model: selectedModel });
          if (okModel) setStatus('Model is ready in Ollama. Continue when you are.', 'ok');
          else setStatus('Pull finished — if chat fails, run ollama list and check the tag matches.', 'busy');
          step = 5;
          setStep(step, state, root);
        } catch (e) {
          setStatus(friendlyPullError(e), 'err');
        } finally {
          unsubscribePullLog();
          if (btn) btn.disabled = false;
        }
      });

    $('ootb-skip-pull') &&
      $('ootb-skip-pull').addEventListener('click', function () {
        setStatus('Skipped download — ensure this exact model tag exists in Ollama before chatting.', 'busy');
        step = 5;
        setStep(step, state, root);
      });

    $('ootb-nonollama-next') &&
      $('ootb-nonollama-next').addEventListener('click', function () {
        step = 5;
        setStep(step, state, root);
        setStatus('');
      });

    $('ootb-back-4') &&
      $('ootb-back-4').addEventListener('click', function () {
        step = 3;
        setStep(step, state, root);
        setStatus('');
      });

    function finishWizardSuccess() {
      var ov = $('ootb-success-overlay');
      var reduced = false;
      try {
        reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
      } catch (_) {}
      if (ov) {
        ov.classList.add('visible');
        ov.setAttribute('aria-hidden', 'false');
      }
      var delay = reduced ? 280 : 920;
      window.setTimeout(function () {
        localStorage.setItem('chump_ootb_complete', '1');
        localStorage.removeItem('chump_ootb_dismissed');
        if (ov) {
          ov.classList.remove('visible');
          ov.setAttribute('aria-hidden', 'true');
        }
        show(root, false);
        setShellInert(false);
        setWindowTitleForWizard(false);
        window.dispatchEvent(new Event('chump-ootb-finished'));
        window.setTimeout(function () {
          window.dispatchEvent(new Event('chump-api-root-ready'));
        }, 80);
        setStatus('');
      }, delay);
    }

    async function tryStartEngine() {
      setStatus('Starting Chump and waiting for /api/health…', 'busy');
      var btn = $('ootb-start-chump');
      var retry = $('ootb-retry-engine');
      if (btn) btn.disabled = true;
      if (retry) retry.style.display = 'none';
      var succeeded = false;
      try {
        var inv = tauriInvoke('try_bring_sidecar_online', { force: true });
        var res = inv && inv.then ? await inv : null;
        if (res && res.ok === true && res.health === true) {
          succeeded = true;
          finishWizardSuccess();
        } else {
          var reason = friendlyEngineReason(res && res.reason);
          setStatus(reason, 'err');
          if (retry) {
            retry.style.display = 'inline-block';
            retry.focus();
          }
        }
      } catch (err) {
        setStatus(String(err), 'err');
        if (retry) {
          retry.style.display = 'inline-block';
          retry.focus();
        }
      } finally {
        if (btn && !succeeded) btn.disabled = false;
      }
    }

    $('ootb-start-chump') && $('ootb-start-chump').addEventListener('click', function () {
      void tryStartEngine();
    });

    $('ootb-retry-engine') &&
      $('ootb-retry-engine').addEventListener('click', function () {
        void tryStartEngine();
      });

    $('ootb-back-5') &&
      $('ootb-back-5').addEventListener('click', function () {
        step = 4;
        setStep(step, state, root);
        setStatus('');
      });

    void refreshOllama();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function () {
      void main();
    });
  } else {
    void main();
  }
})();
