#!/usr/bin/env bash
# render-third-peer.sh — the RENDERER for the Third-Peer transfer ledger.
#
# Pure: JSON in -> HTML out. No network. Reads the shared faculty-status.json
# contract and writes a self-contained page where EVERY dot position and fill
# width is COMPUTED FROM the JSON's "position" field — never hand-drawn.
#
#   width = position * 100%      (fill bar)
#   left  = position * 100%      (dot on the OURS->HAND->ORGAN->PEER track)
#   hue   = warm(ember) if state in {ours,hand}   (being forged)
#           cool(teal)  if state in {organ,peer}  (running)
#
# Contract shape (authoritative — produced by the data faculty agent):
#   { "generated_at": "...", "faculties": [ {key,name,question,value,unit,
#       position(0..1),state(ours|hand|organ|peer),organ,note}, ... ],
#     "frontier": {...} }
#
# POSITION RULE (documented so code and data agree): band by state —
#   ours 0.02-0.24 · hand 0.25-0.49 · organ 0.50-0.74 · peer 0.75-0.97 —
# and place WITHIN the band by the real signal. Monotone: better signal =>
# higher position. When .faculties is present the renderer trusts those
# positions verbatim. When it isn't (the pre-contract RAW-signal shape), the
# renderer applies the SAME POSITION RULE as a compatibility shim so the page
# still renders honest, computed dots. The instant a contract file exists the
# shim is bypassed entirely.
#
# Usage: render-third-peer.sh [INPUT_JSON] [OUTPUT_HTML]
#   INPUT_JSON   default: ~/.chump/faculty-status.json
#   OUTPUT_HTML  default: ~/.chump/third-peer.html
set -euo pipefail

IN="${1:-$HOME/.chump/faculty-status.json}"
OUT="${2:-$HOME/.chump/third-peer.html}"

command -v jq >/dev/null 2>&1 || { echo "render-third-peer: jq required" >&2; exit 2; }
[ -f "$IN" ] || { echo "render-third-peer: input not found: $IN" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Normalize either shape -> one flat stream. First line is the generated_at
# stamp; every following line is one faculty as TAB-separated fields:
#   key \t name \t question \t display \t position \t state \t organ \t note
# ---------------------------------------------------------------------------
NORM="$(jq -r '
  # --- POSITION RULE ---------------------------------------------------------
  def bands: {ours:[0.02,0.24], hand:[0.25,0.49], organ:[0.50,0.74], peer:[0.75,0.97]};
  def clamp(x): (if x < 0 then 0 elif x > 1 then 1 else x end);
  def place($state; $signal):
    (bands[$state]) as $b | ($b[0] + ($b[1]-$b[0]) * clamp($signal));

  def gen: (.generated_at // .ts // "unknown");

  # display value string from a contract faculty
  def cdisplay: ((.value|tostring)
                 + (if (.unit // "") != "" then " " + .unit else "" end));

  if has("faculties") then
    # ---- AUTHORITATIVE CONTRACT PATH: positions read verbatim --------------
    [ gen ]
    + ( .faculties | map(
        [ (.key // "?"), (.name // .key // "?"), (.question // ""),
          cdisplay, ((.position // 0)|tostring), (.state // "ours"),
          (.organ // ""), (.note // "") ] | @tsv ) )
    | .[]
  else
    # ---- COMPAT SHIM: raw-signal shape -> POSITION RULE --------------------
    . as $r
    | ($r.build_merges_24h // 0)      as $merges
    | ($r.see_symbol_pct // 0)        as $sym
    | ($r.see_summary_pct // 0)       as $sum
    | ($r.resolve_organ // "")        as $resolve
    | ($r.know_brier // "null")       as $brier
    | ($r.verify_falsefails // 0)     as $ff
    | ($r.heal_active // 0)           as $ha
    | ($r.heal_manifest // 0)         as $hm
    | ($r.communicate_msgs // 0)      as $msgs
    | (($sym + $sum) / 2 / 100)       as $see_sig
    | (if ($resolve|tostring) == "active" then 0.85 else 0.20 end) as $res_sig
    | (if ($hm > 0) then ($ha / $hm) else 0 end) as $heal_ratio
    | (if (($brier|tostring) == "null" or $brier == null) then null
       else (1 - ($brier|tonumber)) end) as $know_sig
    | ( 1 - ($ff/20) ) as $ver_sig
    | ( $msgs/50 )     as $com_sig
    | [ gen ]
    + [
        ([ "build","Build","intent -> shipped work",
           "\($merges) merges/24h", (place("peer"; $merges/60)|tostring),
           "peer", "run-fleet · workers",
           "factory ships on its own; \($merges) merges in 24h" ] | @tsv),

        ([ "see","See","can it read the code like we do?",
           "\($sym)% symbols · \($sum)% summaries",
           (place("organ"; $see_sig)|tostring),
           "organ", "almanac index",
           "symbol+summary coverage still thin; crossing" ] | @tsv),

        ([ "resolve","Resolve","turn a gap into a claimed plan",
           (if ($resolve|tostring)!="" then ($resolve|tostring) else "—" end),
           (place("organ"; $res_sig)|tostring),
           "organ", "architect · decompose",
           "resolve organ \($resolve); crossing" ] | @tsv),

        ([ "know_score","Know-Score","score its own confidence",
           (if (($brier|tostring)=="null" or $brier==null) then "no brier yet"
            else "brier \($brier)" end),
           (if $know_sig==null then (place("hand"; 0)|tostring)
            else (place("organ"; $know_sig)|tostring) end),
           (if $know_sig==null then "hand" else "organ" end),
           "brier calib", "no calibrated brier yet; being forged" ] | @tsv),

        ([ "verify","Verify","prove the work is real, not green-façade",
           "\($ff) false-fails/24h",
           (place("organ"; $ver_sig)|tostring),
           "organ", "gate gauntlet",
           "\($ff) false-fails leaking through; crossing" ] | @tsv),

        ([ "heal","Heal","fix its own broken organs",
           "\($ha)/\($hm) active (\(($heal_ratio*100)|floor)%)",
           (place("hand"; $heal_ratio)|tostring),
           "hand", "organ-watchdog",
           "\($ha) of \($hm) manifest organs live; partial" ] | @tsv),

        ([ "remember","Remember","carry context across compaction",
           "memory files",
           (place("organ"; 0)|tostring),
           "organ", "auto-memory",
           "memory organ exists; no live signal wired yet" ] | @tsv),

        ([ "aim","Aim","choose what matters without us",
           "—",
           (place("ours"; 0)|tostring),
           "ours", "INFRA-737 operator",
           "still ours; the OS does not yet set its own aim" ] | @tsv),

        ([ "communicate","Communicate","speak to the human on its own",
           "\($msgs) msgs/24h",
           (place("ours"; $com_sig)|tostring),
           "ours", "discord-gateway",
           (if $msgs==0 then "dark — 0 messages in 24h" else "\($msgs) msgs" end) ] | @tsv),

        ([ "conscience","Conscience","hold the line when we are wrong",
           "—",
           (place("ours"; 0)|tostring),
           "ours", "—",
           "still ours; the hardest and last rung" ] | @tsv),

        ([ "learn","Learn","get better from its own laps",
           "—",
           (place("ours"; 0)|tostring),
           "ours", "—",
           "still ours; no self-improvement loop wired" ] | @tsv)
      ]
    | .[]
  end
' "$IN")"

GEN="$(printf '%s\n' "$NORM" | head -n1)"
ROWS_TSV="$(printf '%s\n' "$NORM" | tail -n +2)"

# HTML escape helper
esc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
# round a 0..1 float to a percentage with one decimal, pure awk
pct() { awk -v p="$1" 'BEGIN{ if(p<0)p=0; if(p>1)p=1; printf "%.1f", p*100 }'; }

# ---------------------------------------------------------------------------
# Build the faculty rows
# ---------------------------------------------------------------------------
ROWS_HTML=""
while IFS=$'\t' read -r key name question display position state organ note; do
  [ -z "${key:-}" ] && continue
  w="$(pct "$position")"
  case "$state" in
    ours|hand) hue="warm" ;;
    *)         hue="cool" ;;
  esac
  ROWS_HTML+="
      <div class=\"row $hue\" data-state=\"$(esc "$state")\">
        <div class=\"rmeta\">
          <div class=\"rname\">$(esc "$name")</div>
          <div class=\"rq\">$(esc "$question")</div>
        </div>
        <div class=\"track\" title=\"$(esc "$note")\">
          <span class=\"fill\" style=\"width:${w}%\"></span>
          <span class=\"dot\" style=\"left:${w}%\"></span>
        </div>
        <div class=\"rdata\">
          <div class=\"rval\">$(esc "$display")</div>
          <div class=\"rstate\">$(esc "$state") &middot; ${w}%</div>
          <div class=\"rorgan\">$(esc "$organ")</div>
        </div>
      </div>"
done <<< "$ROWS_TSV"

SRC_NAME="$(basename "$IN")"

# ---------------------------------------------------------------------------
# Emit the self-contained page
# ---------------------------------------------------------------------------
cat > "$OUT" <<HTMLDOC
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Third Peer &middot; Transfer Ledger</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Newsreader:ital,opsz,wght@0,6..72,400;0,6..72,500;1,6..72,400&family=IBM+Plex+Sans:wght@400;500;600&family=IBM+Plex+Mono:wght@400;500&display=swap" rel="stylesheet">
<style>
  :root{
    /* dark-first ground */
    --ground:#0C1116; --panel:#121a22; --panel-2:#0f151b;
    --ink:#E7EEF4; --ink-dim:#9fb0bf; --ink-faint:#66788a;
    --line:#1e2a35; --line-2:#26333f;
    --ember:#EE9A4D;   /* ours / being forged */
    --ember-soft:#7a5327;
    --teal:#4FD8C4;    /* running */
    --teal-soft:#245b53;
    --track:#0b1017; --track-line:#22303c;
  }
  :root[data-theme="dark"]{ color-scheme:dark; }
  @media (prefers-color-scheme:light){
    :root:not([data-theme="dark"]){
      --ground:#F5F1E8; --panel:#FBF8F1; --panel-2:#efe9dc;
      --ink:#1b2733; --ink-dim:#4a5b6b; --ink-faint:#8395a3;
      --line:#e3dccc; --line-2:#d8cfba;
      --ember:#C9761F; --ember-soft:#e6c193;
      --teal:#128c78; --teal-soft:#a7e3d8;
      --track:#efe9dc; --track-line:#d8cfba;
      color-scheme:light;
    }
  }
  :root[data-theme="light"]{
    --ground:#F5F1E8; --panel:#FBF8F1; --panel-2:#efe9dc;
    --ink:#1b2733; --ink-dim:#4a5b6b; --ink-faint:#8395a3;
    --line:#e3dccc; --line-2:#d8cfba;
    --ember:#C9761F; --ember-soft:#e6c193;
    --teal:#128c78; --teal-soft:#a7e3d8;
    --track:#efe9dc; --track-line:#d8cfba;
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
  .wrap{max-width:1040px; margin:0 auto}
  header{margin-bottom:clamp(20px,3vw,34px)}
  .kicker{
    font-family:"IBM Plex Mono",ui-monospace,monospace;
    font-size:12px; letter-spacing:.22em; text-transform:uppercase;
    color:var(--ink-faint); margin:0 0 10px;
  }
  h1{
    font-family:"Newsreader",Georgia,serif; font-weight:500;
    font-size:clamp(30px,5vw,52px); line-height:1.05; margin:0 0 12px;
    letter-spacing:-.01em;
  }
  .lede{
    max-width:60ch; color:var(--ink-dim); font-size:15.5px; margin:0 0 4px;
  }
  .lede em{font-style:italic; color:var(--ink)}
  .stamp{
    font-family:"IBM Plex Mono",monospace; font-size:11.5px;
    color:var(--ink-faint); margin-top:14px;
  }
  .stamp b{color:var(--teal); font-weight:500}

  /* legend of the four bands */
  .axis{
    display:grid; grid-template-columns:1fr 1fr 1fr 1fr; gap:0;
    margin:26px 0 6px; border:1px solid var(--line);
    border-radius:10px; overflow:hidden;
    font-family:"IBM Plex Mono",monospace; font-size:11px; letter-spacing:.14em;
  }
  .axis span{
    text-transform:uppercase; padding:9px 12px; text-align:center;
    color:var(--ink-faint); background:var(--panel-2);
    border-right:1px solid var(--line);
  }
  .axis span:last-child{border-right:0}
  .axis .a-ours,.axis .a-hand{color:var(--ember)}
  .axis .a-organ,.axis .a-peer{color:var(--teal)}

  .ledger{
    border:1px solid var(--line); border-radius:14px; overflow:hidden;
    background:linear-gradient(180deg,var(--panel),var(--panel-2));
  }
  .row{
    display:grid;
    grid-template-columns:minmax(170px,1.15fr) minmax(220px,2.4fr) minmax(150px,1.15fr);
    gap:clamp(12px,2.4vw,26px); align-items:center;
    padding:16px clamp(14px,2.4vw,24px);
    border-top:1px solid var(--line);
  }
  .row:first-child{border-top:0}
  .rname{
    font-family:"Newsreader",Georgia,serif; font-size:21px; font-weight:500;
    letter-spacing:-.01em;
  }
  .rq{font-size:12.5px; color:var(--ink-faint); margin-top:2px}

  .track{
    position:relative; height:12px; border-radius:999px;
    background:var(--track); border:1px solid var(--track-line);
  }
  /* four faint band separators at 25/50/75% */
  .track::before{
    content:""; position:absolute; inset:0; border-radius:999px;
    background:
      linear-gradient(90deg,transparent 24.6%,var(--track-line) 24.6%,var(--track-line) 25.4%,transparent 25.4%),
      linear-gradient(90deg,transparent 49.6%,var(--track-line) 49.6%,var(--track-line) 50.4%,transparent 50.4%),
      linear-gradient(90deg,transparent 74.6%,var(--track-line) 74.6%,var(--track-line) 75.4%,transparent 75.4%);
    opacity:.7; pointer-events:none;
  }
  .fill{
    position:absolute; left:0; top:0; bottom:0; border-radius:999px;
    background:linear-gradient(90deg,color-mix(in srgb,var(--_c) 55%,transparent),var(--_c));
  }
  .dot{
    position:absolute; top:50%; width:16px; height:16px; border-radius:50%;
    transform:translate(-50%,-50%);
    background:var(--_c);
    box-shadow:0 0 0 4px color-mix(in srgb,var(--_c) 22%,transparent),
               0 0 14px 1px color-mix(in srgb,var(--_c) 55%,transparent);
  }
  .row.warm{--_c:var(--ember)}
  .row.cool{--_c:var(--teal)}

  .rdata{text-align:right}
  .rval{
    font-family:"IBM Plex Mono",monospace; font-size:13px; color:var(--ink);
  }
  .rstate{
    font-family:"IBM Plex Mono",monospace; font-size:11px;
    text-transform:uppercase; letter-spacing:.1em; margin-top:3px;
    color:var(--ink-faint);
  }
  .row.warm .rstate{color:var(--ember)}
  .row.cool .rstate{color:var(--teal)}
  .rorgan{font-size:11.5px; color:var(--ink-faint); margin-top:2px}

  footer{
    margin-top:22px; display:flex; justify-content:space-between;
    align-items:center; gap:14px; flex-wrap:wrap;
    font-family:"IBM Plex Mono",monospace; font-size:11px; color:var(--ink-faint);
  }
  .key{display:flex; gap:16px; align-items:center}
  .key i{display:inline-block; width:10px; height:10px; border-radius:50%; margin-right:6px; vertical-align:-1px}
  .key .kw{background:var(--ember)} .key .kc{background:var(--teal)}
  .tbtn{
    font:inherit; color:var(--ink-dim); background:var(--panel-2);
    border:1px solid var(--line); border-radius:7px; padding:5px 11px; cursor:pointer;
  }
  .tbtn:hover{color:var(--ink); border-color:var(--line-2)}

  @media (max-width:640px){
    .row{grid-template-columns:1fr; gap:10px}
    .rdata{text-align:left}
    .axis{font-size:9.5px}
  }
</style>
</head>
<body>
  <div class="wrap">
    <header>
      <p class="kicker">ChumpOS &middot; Third Peer</p>
      <h1>The Transfer Ledger</h1>
      <p class="lede">Eleven faculties. Each one starts <em>ours</em> and is forged
        across the track until the factory carries it as a <em>peer</em>. Ember is
        still in our hands; teal is running on its own.</p>
      <p class="stamp">${GEN} &middot; <b>live from ${SRC_NAME}</b></p>
    </header>

    <div class="axis">
      <span class="a-ours">Ours</span>
      <span class="a-hand">Hand</span>
      <span class="a-organ">Organ</span>
      <span class="a-peer">Peer</span>
    </div>

    <div class="ledger">$ROWS_HTML
    </div>

    <footer>
      <div class="key">
        <span><i class="kw"></i>ours / hand &mdash; being forged</span>
        <span><i class="kc"></i>organ / peer &mdash; running</span>
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

echo "render-third-peer: wrote $OUT (source: $IN, stamp: $GEN)"
