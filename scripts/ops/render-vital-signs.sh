#!/usr/bin/env bash
# render-vital-signs.sh — the RENDERER for the ChumpOS Vital Signs board.
#
# Pure: JSON in -> HTML out. No network. Reads the shared vital-signs.json
# contract and writes a self-contained dashboard. Nothing here computes a
# signal or a status; every value, status, and threshold is read VERBATIM
# from the contract. A sign whose source is not wired renders greyed
# "unknown" — never fake-green.
#
# Contract shape (authoritative — produced by the vital-signs collector):
#   { "generated_at": "...",
#     "p_full_trek": 0.45 | null,          # roll-up hero number (0..1)
#     "signs": [ {
#        "key","name",
#        "group":"flow|quality|waste|trust|autonomy|mission",
#        "lead_or_lag":"leading|lagging",
#        "value", "unit",
#        "status":"green|amber|red|unknown",
#        "thresholds": {"green":..,"amber":..,"red_desc":".."},
#        "treatable_action":"..",
#        "basis":".."
#     }, ... ] }
#
# Semantic status colour (green/amber/red/unknown) is SEPARATE from the
# ember/teal brand accent. Status drives the pill + tile edge; the brand
# accent stays on the hero roll-up and typographic furniture.
#
# Usage: render-vital-signs.sh [INPUT_JSON] [OUTPUT_HTML]
#   INPUT_JSON   default: ~/.chump/vital-signs.json
#   OUTPUT_HTML  default: ~/.chump/vital-signs.html
set -euo pipefail

IN="${1:-$HOME/.chump/vital-signs.json}"
OUT="${2:-$HOME/.chump/vital-signs.html}"

command -v jq >/dev/null 2>&1 || { echo "render-vital-signs: jq required" >&2; exit 2; }
[ -f "$IN" ] || { echo "render-vital-signs: input not found: $IN" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Normalize the contract -> one flat stream, fields joined by US (\x1f).
# A NON-whitespace separator is deliberate: TAB is an IFS-whitespace char, so
# `read` would COLLAPSE consecutive empty fields (a null value beside an empty
# unit) and silently shift every later column. US preserves empty fields.
#   line 1: generated_at
#   line 2: p_full_trek (raw float, or the literal "null")
#   line 3+: one sign per line, fields (US-separated):
#     key · name · group · lead_or_lag · value · unit · status ·
#     thr_green · thr_amber · thr_red · action · basis
# Missing sub-fields default to "" and status defaults to "unknown".
# ---------------------------------------------------------------------------
US=$'\x1f'
NORM="$(jq -j '
  def s(x): (x // "" | tostring | gsub("[\\n\\r]";" "));
  def row: [ s(.key), s(.name), s(.group), s(.lead_or_lag),
      s(.value), s(.unit),
      (.status // "unknown" | tostring),
      s(.thresholds.green), s(.thresholds.amber), s(.thresholds.red_desc),
      s(.treatable_action), s(.basis) ] | join("\u001f");
  (.generated_at // "unknown"), "\n",
  (if (.p_full_trek == null) then "null" else (.p_full_trek|tostring) end), "\n",
  ( (.signs // []) | map(row) | join("\n") )
' "$IN")"

GEN="$(printf '%s\n' "$NORM" | sed -n '1p')"
PTREK="$(printf '%s\n' "$NORM" | sed -n '2p')"
ROWS_TSV="$(printf '%s\n' "$NORM" | tail -n +3)"

esc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# hero percentage from p_full_trek (0..1). "null" -> em dash.
if [ "$PTREK" = "null" ] || [ -z "$PTREK" ]; then
  HERO="&mdash;"
  HERO_SUB="p(full Trek) not yet instrumented"
else
  HERO="$(awk -v p="$PTREK" 'BEGIN{ if(p<0)p=0; if(p>1)p=1; printf "%.0f", p*100 }')%"
  HERO_SUB="probability an intent completes the full Trek"
fi

# ---------------------------------------------------------------------------
# Group ordering + human labels (the six vital-sign systems).
# ---------------------------------------------------------------------------
group_label() {
  case "$1" in
    flow)     echo "Flow" ;;
    quality)  echo "Quality" ;;
    waste)    echo "Waste" ;;
    trust)    echo "Trust" ;;
    autonomy) echo "Autonomy" ;;
    mission)  echo "Mission" ;;
    *)        echo "$1" ;;
  esac
}
GROUP_ORDER="flow quality waste trust autonomy mission"

# render one tile from the current IFS-split fields (globals set by loop)
render_tile() {
  local key="$1" name="$2" ll="$3" value="$4" unit="$5" status="$6"
  local tg="$7" ta="$8" tr="$9" action="${10}" basis="${11}"
  local pill val display llabel
  case "$status" in
    green)   pill="GREEN";  status_cls="ok" ;;
    amber)   pill="AMBER";  status_cls="warn" ;;
    red)     pill="RED";    status_cls="bad" ;;
    *)       pill="UNKNOWN"; status_cls="unknown"; status="unknown" ;;
  esac
  # value + unit display
  if [ "$status_cls" = "unknown" ] && { [ -z "$value" ] || [ "$value" = "null" ]; }; then
    display="&mdash;"
  else
    display="$(esc "$value")"
    [ -n "$unit" ] && display="$display <span class=\"unit\">$(esc "$unit")</span>"
  fi
  case "$ll" in
    leading) llabel="leading" ;;
    lagging) llabel="lagging" ;;
    *)       llabel="$(esc "$ll")" ;;
  esac
  # threshold line — show whichever bounds exist
  local thr=""
  [ -n "$tg" ] && thr="${thr}green $(esc "$tg")"
  [ -n "$ta" ] && { [ -n "$thr" ] && thr="$thr &middot; "; thr="${thr}amber $(esc "$ta")"; }
  [ -n "$tr" ] && { [ -n "$thr" ] && thr="$thr &middot; "; thr="${thr}red $(esc "$tr")"; }
  [ -z "$thr" ] && thr="uninstrumented"

  printf '%s' "
        <div class=\"tile $status_cls\">
          <div class=\"thead\">
            <div class=\"tname\">$(esc "$name")</div>
            <span class=\"pill\">$pill</span>
          </div>
          <div class=\"tval\">$display</div>
          <div class=\"ttags\">
            <span class=\"tag ll-$llabel\">$llabel</span>
            <span class=\"thr\">$thr</span>
          </div>
          <div class=\"taction\">$(esc "$action")</div>
        </div>"
}

# ---------------------------------------------------------------------------
# Bucket rows by group into temp files (preserve JSON order within group).
# ---------------------------------------------------------------------------
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/vsigns.XXXXXX")"
trap 'rm -rf "$TMPD"' EXIT

while IFS="$US" read -r key name group ll value unit status tg ta tr action basis; do
  [ -z "${key:-}" ] && continue
  printf '%s\n' "${key}${US}${name}${US}${group}${US}${ll}${US}${value}${US}${unit}${US}${status}${US}${tg}${US}${ta}${US}${tr}${US}${action}${US}${basis}" \
    >> "$TMPD/g.$group"
done <<< "$ROWS_TSV"

SECTIONS_HTML=""
for g in $GROUP_ORDER; do
  [ -f "$TMPD/g.$g" ] || continue
  glabel="$(group_label "$g")"
  tiles=""
  while IFS="$US" read -r key name group ll value unit status tg ta tr action basis; do
    [ -z "${key:-}" ] && continue
    tiles+="$(render_tile "$key" "$name" "$ll" "$value" "$unit" "$status" "$tg" "$ta" "$tr" "$action" "$basis")"
  done < "$TMPD/g.$g"
  SECTIONS_HTML+="
      <section class=\"grp\">
        <h2 class=\"glabel\">$(esc "$glabel")</h2>
        <div class=\"tiles\">$tiles
        </div>
      </section>"
done

SRC_NAME="$(basename "$IN")"

# ---------------------------------------------------------------------------
# Emit the self-contained page.
# ---------------------------------------------------------------------------
cat > "$OUT" <<HTMLDOC
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>ChumpOS &middot; Vital Signs</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Newsreader:ital,opsz,wght@0,6..72,400;0,6..72,500;1,6..72,400&family=IBM+Plex+Sans:wght@400;500;600&family=IBM+Plex+Mono:wght@400;500;600&display=swap" rel="stylesheet">
<style>
  :root{
    /* dark-first ground — matches the Third-Peer / journey instruments */
    --ground:#0C1116; --panel:#121a22; --panel-2:#0f151b;
    --ink:#E7EEF4; --ink-dim:#9fb0bf; --ink-faint:#66788a;
    --line:#1e2a35; --line-2:#26333f;
    /* BRAND accent (identity, not status) */
    --ember:#EE9A4D; --teal:#4FD8C4;
    /* SEMANTIC status (separate from brand) */
    --ok:#4FD8C4; --ok-ink:#0C1116; --ok-bg:#0f2621; --ok-edge:#245b53;
    --warn:#EEC24D; --warn-ink:#0C1116; --warn-bg:#2a2410; --warn-edge:#6b591f;
    --bad:#F0705A; --bad-ink:#0C1116; --bad-bg:#2a1410; --bad-edge:#6b2c22;
    --unk:#66788a; --unk-ink:#0C1116; --unk-bg:#141b22; --unk-edge:#2a3844;
  }
  :root[data-theme="dark"]{ color-scheme:dark; }
  @media (prefers-color-scheme:light){
    :root:not([data-theme="dark"]){
      --ground:#F5F1E8; --panel:#FBF8F1; --panel-2:#efe9dc;
      --ink:#1b2733; --ink-dim:#4a5b6b; --ink-faint:#8395a3;
      --line:#e3dccc; --line-2:#d8cfba;
      --ember:#C9761F; --teal:#128c78;
      --ok:#128c78; --ok-ink:#ffffff; --ok-bg:#e2f2ee; --ok-edge:#9cdccf;
      --warn:#B8860B; --warn-ink:#ffffff; --warn-bg:#f6eecf; --warn-edge:#e0cf94;
      --bad:#C0432E; --bad-ink:#ffffff; --bad-bg:#f8e2dc; --bad-edge:#e6b3a6;
      --unk:#8395a3; --unk-ink:#ffffff; --unk-bg:#efe9dc; --unk-edge:#d8cfba;
      color-scheme:light;
    }
  }
  :root[data-theme="light"]{
    --ground:#F5F1E8; --panel:#FBF8F1; --panel-2:#efe9dc;
    --ink:#1b2733; --ink-dim:#4a5b6b; --ink-faint:#8395a3;
    --line:#e3dccc; --line-2:#d8cfba;
    --ember:#C9761F; --teal:#128c78;
    --ok:#128c78; --ok-ink:#ffffff; --ok-bg:#e2f2ee; --ok-edge:#9cdccf;
    --warn:#B8860B; --warn-ink:#ffffff; --warn-bg:#f6eecf; --warn-edge:#e0cf94;
    --bad:#C0432E; --bad-ink:#ffffff; --bad-bg:#f8e2dc; --bad-edge:#e6b3a6;
    --unk:#8395a3; --unk-ink:#ffffff; --unk-bg:#efe9dc; --unk-edge:#d8cfba;
    color-scheme:light;
  }
  *{box-sizing:border-box}
  html,body{margin:0}
  body{
    background:var(--ground); color:var(--ink);
    font-family:"IBM Plex Sans",system-ui,-apple-system,Segoe UI,Roboto,sans-serif;
    -webkit-font-smoothing:antialiased; line-height:1.45;
    padding:clamp(18px,4vw,54px);
  }
  .wrap{max-width:1080px; margin:0 auto}
  .kicker{
    font-family:"IBM Plex Mono",ui-monospace,monospace;
    font-size:12px; letter-spacing:.22em; text-transform:uppercase;
    color:var(--ink-faint); margin:0 0 10px;
  }

  /* ---- HERO: the p(full Trek) roll-up -------------------------------- */
  .hero{
    display:flex; align-items:baseline; gap:clamp(16px,3vw,30px);
    flex-wrap:wrap; margin-bottom:6px;
  }
  .hnum{
    font-family:"Newsreader",Georgia,serif; font-weight:500;
    font-size:clamp(64px,13vw,132px); line-height:.9; letter-spacing:-.02em;
    color:var(--ink);
    background:linear-gradient(180deg,var(--ember),var(--teal));
    -webkit-background-clip:text; background-clip:text;
    -webkit-text-fill-color:transparent;
  }
  .htext h1{
    font-family:"Newsreader",Georgia,serif; font-weight:500;
    font-size:clamp(22px,3.4vw,34px); line-height:1.05; margin:0 0 6px;
    letter-spacing:-.01em;
  }
  .htext p{margin:0; color:var(--ink-dim); font-size:14.5px; max-width:46ch}
  .stamp{
    font-family:"IBM Plex Mono",monospace; font-size:11.5px;
    color:var(--ink-faint); margin:16px 0 30px;
  }
  .stamp b{color:var(--teal); font-weight:500}

  /* ---- GROUPS + TILES ------------------------------------------------ */
  .grp{margin:0 0 26px}
  .glabel{
    font-family:"IBM Plex Mono",monospace; font-size:12px; font-weight:600;
    letter-spacing:.2em; text-transform:uppercase; color:var(--ink-faint);
    margin:0 0 12px; padding-bottom:8px; border-bottom:1px solid var(--line);
  }
  .tiles{
    display:grid; gap:14px;
    grid-template-columns:repeat(auto-fill,minmax(255px,1fr));
  }
  .tile{
    background:linear-gradient(180deg,var(--panel),var(--panel-2));
    border:1px solid var(--line); border-left:3px solid var(--_edge,var(--line));
    border-radius:12px; padding:15px 16px 14px;
  }
  .tile.ok{--_c:var(--ok); --_ink:var(--ok-ink); --_bg:var(--ok-bg); --_edge:var(--ok-edge)}
  .tile.warn{--_c:var(--warn); --_ink:var(--warn-ink); --_bg:var(--warn-bg); --_edge:var(--warn-edge)}
  .tile.bad{--_c:var(--bad); --_ink:var(--bad-ink); --_bg:var(--bad-bg); --_edge:var(--bad-edge)}
  .tile.unknown{--_c:var(--unk); --_ink:var(--unk-ink); --_bg:var(--unk-bg); --_edge:var(--unk-edge); opacity:.9}
  .thead{display:flex; align-items:center; justify-content:space-between; gap:10px}
  .tname{
    font-family:"Newsreader",Georgia,serif; font-size:19px; font-weight:500;
    letter-spacing:-.01em;
  }
  .pill{
    font-family:"IBM Plex Mono",monospace; font-size:10px; font-weight:600;
    letter-spacing:.12em; padding:3px 8px; border-radius:999px;
    color:var(--_ink); background:var(--_c);
    border:1px solid color-mix(in srgb,var(--_c) 60%,transparent);
    white-space:nowrap;
  }
  .tile.unknown .pill{color:var(--ink-dim); background:var(--_bg); border-color:var(--_edge)}
  .tval{
    font-family:"IBM Plex Mono",monospace; font-size:30px; font-weight:500;
    color:var(--ink); margin:10px 0 8px; line-height:1;
  }
  .tval .unit{font-size:13px; color:var(--ink-faint); font-weight:400; margin-left:2px}
  .tile.unknown .tval{color:var(--ink-faint)}
  .ttags{display:flex; align-items:center; gap:8px; flex-wrap:wrap; margin-bottom:9px}
  .tag{
    font-family:"IBM Plex Mono",monospace; font-size:9.5px; letter-spacing:.1em;
    text-transform:uppercase; padding:2px 7px; border-radius:5px;
    border:1px solid var(--line-2); color:var(--ink-faint);
  }
  .tag.ll-leading{color:var(--teal); border-color:color-mix(in srgb,var(--teal) 45%,transparent)}
  .tag.ll-lagging{color:var(--ember); border-color:color-mix(in srgb,var(--ember) 45%,transparent)}
  .thr{
    font-family:"IBM Plex Mono",monospace; font-size:10.5px; color:var(--ink-faint);
  }
  .taction{
    font-size:12px; color:var(--ink-dim); line-height:1.4;
    padding-top:9px; border-top:1px dashed var(--line);
  }

  footer{
    margin-top:14px; display:flex; justify-content:space-between;
    align-items:center; gap:14px; flex-wrap:wrap;
    font-family:"IBM Plex Mono",monospace; font-size:11px; color:var(--ink-faint);
  }
  .key{display:flex; gap:14px; align-items:center; flex-wrap:wrap}
  .key i{display:inline-block; width:10px; height:10px; border-radius:3px; margin-right:6px; vertical-align:-1px}
  .key .ko{background:var(--ok)} .key .kw{background:var(--warn)}
  .key .kb{background:var(--bad)} .key .ku{background:var(--unk)}
  .tbtn{
    font:inherit; color:var(--ink-dim); background:var(--panel-2);
    border:1px solid var(--line); border-radius:7px; padding:5px 11px; cursor:pointer;
  }
  .tbtn:hover{color:var(--ink); border-color:var(--line-2)}

  @media (max-width:520px){
    .tiles{grid-template-columns:1fr}
    .hnum{font-size:clamp(56px,20vw,90px)}
  }
</style>
</head>
<body>
  <div class="wrap">
    <p class="kicker">ChumpOS &middot; Vital Signs</p>
    <div class="hero">
      <div class="hnum">${HERO}</div>
      <div class="htext">
        <h1>p(full Trek)</h1>
        <p>${HERO_SUB} &mdash; boot &rarr; install &rarr; provision &rarr; point
           &rarr; work &rarr; gate &rarr; merge &rarr; live.</p>
      </div>
    </div>
    <p class="stamp">${GEN} &middot; <b>live from ${SRC_NAME}</b></p>
${SECTIONS_HTML}
    <footer>
      <div class="key">
        <span><i class="ko"></i>green</span>
        <span><i class="kw"></i>amber</span>
        <span><i class="kb"></i>red</span>
        <span><i class="ku"></i>unknown &mdash; uninstrumented, not fake-green</span>
      </div>
      <button class="tbtn" id="tbtn" type="button">toggle theme</button>
    </footer>
  </div>
<script>
  (function(){
    var b=document.getElementById('tbtn'), r=document.documentElement;
    b.addEventListener('click',function(){
      var cur=r.getAttribute('data-theme');
      if(!cur){cur=matchMedia('(prefers-color-scheme:dark)').matches?'dark':'light';}
      r.setAttribute('data-theme', cur==='dark'?'light':'dark');
    });
  })();
</script>
</body>
</html>
HTMLDOC

echo "render-vital-signs: wrote $OUT (source: $IN, stamp: $GEN, p_full_trek: $PTREK)"
