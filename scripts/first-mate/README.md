# first-mate gap-store tools

All gap-store readers here resolve the canonical node via
`CHUMP_CANONICAL_GAP_HOST` > `~/.chump/canonical-gap-host` > `cuphead`
(INFRA-8056). Do not hardcode closetjunky (store moved to cuphead 2026-09-29).

Audit (INFRA-8056 AC3): `gap-show.sh` is the only script in this directory that
reads the gap store. In-repo `grep -rn closetjunky scripts/` shows no other
gap-store readers pointing at CJ (remaining hits are provisioning/node-registry
scripts, not gap reads).
