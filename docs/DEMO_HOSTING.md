---
doc_tag: runbook
owner_gap:
last_audited: 2026-04-25
---

# Hosting Chump CLI Demo on GitHub Pages

Self-hosted asciinema recordings on GitHub Pages. No third-party dependencies, full control.

---

## One-time Setup

### 1. Enable GitHub Pages in repository settings

Go to https://github.com/repairman29/chump/settings/pages
- **Source:** Deploy from a branch
- **Branch:** `main` / folder: `/docs`

### 2. Create demo directory structure

```bash
mkdir -p docs/demo/assets
```

### 3. Add asciinema player library

Create `docs/demo/index.html`:

```html
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>Chump CLI Demo</title>
  <link rel="stylesheet" type="text/css" href="https://cdnjs.cloudflare.com/ajax/libs/asciinema-player/3.7.0/bundle/asciinema-player.min.css" />
  <style>
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      max-width: 1000px;
      margin: 0 auto;
      padding: 20px;
      background: #f5f5f5;
    }
    h1 { color: #333; }
    .description { color: #666; margin-bottom: 20px; }
    .player-container {
      background: white;
      border-radius: 8px;
      padding: 20px;
      box-shadow: 0 2px 4px rgba(0,0,0,0.1);
    }
    asciinema-player {
      max-width: 100%;
    }
  </style>
</head>
<body>
  <h1>🤖 Chump CLI Demo</h1>
  <p class="description">
    3-minute walkthrough of Chump's autonomous gap execution and multi-agent coordination.
    <br>
    <a href="https://github.com/repairman29/chump">View on GitHub</a> • 
    <a href="https://chump.dev">Documentation</a>
  </p>
  
  <div class="player-container">
    <asciinema-player src="demo.cast" cols="140" rows="35"></asciinema-player>
  </div>

  <h2>What You'll See</h2>
  <ul>
    <li><strong>Initialize:</strong> `chump init` sets up a fresh workspace</li>
    <li><strong>List gaps:</strong> View available tasks with priorities and effort estimates</li>
    <li><strong>Autonomous execution:</strong> `chump gap claim` and watch real-time progress</li>
    <li><strong>Ambient coordination:</strong> See multi-agent activity log (ambient.jsonl)</li>
  </ul>

  <h2>Recording Details</h2>
  <p>
    <strong>Date recorded:</strong> <span id="recorded-date">(loading...)</span><br>
    <strong>Duration:</strong> ~3 minutes<br>
    <strong>File size:</strong> <span id="file-size">(loading...)</span>
  </p>

  <script src="https://cdnjs.cloudflare.com/ajax/libs/asciinema-player/3.7.0/bundle/asciinema-player.min.js"></script>
  <script>
    // Load demo.cast metadata
    fetch('demo.cast')
      .then(r => r.text())
      .then(text => {
        const lines = text.split('\n');
        const header = JSON.parse(lines[0]);
        const sizeKb = (text.length / 1024).toFixed(1);
        
        document.getElementById('file-size').textContent = sizeKb + ' KB';
        document.getElementById('recorded-date').textContent = 
          new Date(header.timestamp * 1000).toLocaleDateString();
      });
  </script>
</body>
</html>
```

---

## Recording and Publishing

### 1. Record the demo

```bash
scripts/record-demo.sh docs/demo
# Produces: docs/demo/demo-YYYY-MM-DD-HHMMSS.cast
```

### 2. Copy to standard location

```bash
cp docs/demo/demo-YYYY-MM-DD-HHMMSS.cast docs/demo/demo.cast
```

### 3. Commit and push

```bash
git add docs/demo/
git commit -m "PRODUCT-016: Update CLI demo recording"
git push
```

### 4. Access the demo

Visit: `https://repairman29.github.io/chump/demo/`

---

## Monthly Refresh

Add to `.github/workflows/demo-refresh.yml`:

```yaml
name: Refresh CLI Demo

on:
  schedule:
    # First Monday of month at 10:00 UTC
    - cron: '0 10 1-7 * 1'

jobs:
  record:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Install asciinema
        run: brew install asciinema
      
      - name: Record demo
        run: |
          scripts/record-demo.sh docs/demo
          # Find the newest .cast file and rename to demo.cast
          cp $(ls -t docs/demo/demo-*.cast | head -1) docs/demo/demo.cast
      
      - name: Commit updated demo
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add docs/demo/demo.cast
          git commit -m "chore: refresh CLI demo recording" || true
          git push
```

---

## Comparison: Hosting Options

| Hosting | Pros | Cons |
|---------|------|------|
| **asciinema.org** | Simple, auto-playback, shareable URLs | Depends on 3rd party, limited control |
| **GitHub Pages** | Full control, self-hosted, embeddable | One extra setup step |
| **Embedded video** | Native player, seekable | Requires more storage, not as lightweight |

---

## Troubleshooting

### Demo.cast is too large
- Trim to essential steps only (remove pauses/waits)
- Compress: `gzip docs/demo/demo.cast` (but then update HTML src)

### Recording playback is slow
- Reduce terminal size in `record-demo.sh` (cols/rows)
- Remove animated progress bars (use flags: `--quiet`)

### Index.html not rendering
- Check GitHub Pages settings (Settings > Pages > Branch = main, folder = /docs)
- Wait ~1-2 minutes for GitHub to rebuild

---

## See Also

- [asciinema.org](https://asciinema.org) — Official asciinema platform
- [asciinema-player](https://github.com/asciinema/asciinema-player) — Embedded player docs
- [docs/DEMO_SCRIPT.md](./DEMO_SCRIPT.md) — Demo script annotated guide
