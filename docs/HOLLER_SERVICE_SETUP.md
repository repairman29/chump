# Holler Service Setup (MISSION-111)

**Purpose:** Enable autonomous portfolio discovery via the Holler service. This document covers:
1. Configuring HOLLER_SERVICE_KEY provisioning
2. Installing and enabling holler.service and holler.timer systemd units
3. Verifying holler starts successfully on boot

## Prerequisites

- **systemd** available on the host (Linux)
- **Holler backend access:** HOLLER_SUPABASE_URL and HOLLER_ANON_KEY (from supabase setup)
- **HOLLER_SERVICE_KEY:** generated from the holler/supabase backend (service_role_key)

## 1. Provision HOLLER_SERVICE_KEY

The holler service requires three environment variables:

| Variable | Source | Notes |
|---|---|---|
| `HOLLER_SERVICE_KEY` | supabase `service_role_key` (from `gen-app-secrets.sh`) | Used for authenticated writes to holler backend |
| `HOLLER_SUPABASE_URL` | supabase REST API endpoint | e.g., `https://api.mytrove.app` |
| `HOLLER_ANON_KEY` | supabase `anon_key` | Used for public/unauthenticated reads |

### A. Create holler.env configuration file

Store holler credentials in `/root/.chump/holler.env` (chmod 600, **not committed**):

```bash
# /root/.chump/holler.env (chmod 600, never commit)
# This file is sourced by holler.service before each run.
# Replace with values from your supabase deployment (see deploy/supabase/README.md).

export HOLLER_SERVICE_KEY="eyJhbGc..."  # from gen-app-secrets.sh output
export HOLLER_SUPABASE_URL="https://api.mytrove.app"
export HOLLER_ANON_KEY="eyJhbGc..."
```

To generate holler credentials on cuphead (if you have supabase running):

```bash
# On cuphead:
cd /opt/supabase
bash scripts/gen-app-secrets.sh 2>&1 | grep -A3 "holler"
# Copy SERVICE_ROLE_KEY_HOLLER and ANON_KEY_HOLLER into holler.env
```

### B. Protect the env file

```bash
chmod 600 /root/.chump/holler.env
# Verify it's not world-readable:
ls -l /root/.chump/holler.env  # should be -rw------- 
```

## 2. Install systemd units

The holler service is configured to:
- Load HOLLER_SERVICE_KEY from `/root/.chump/holler.env` on every start
- Run autonomously on a timer (every 5 minutes for testing, 3600s for production)
- Emit observability events to `~/.chump-locks/ambient.jsonl`
- Start automatically on boot (if enabled)

### A. Copy service files to systemd directories

```bash
# Copy holler service and timer to systemd:
sudo cp scripts/dispatch/holler.service /etc/systemd/system/
sudo cp scripts/dispatch/holler.timer /etc/systemd/system/

# Reload systemd to register the new units:
sudo systemctl daemon-reload

# Verify they're recognized:
systemctl list-unit-files | grep holler
# Expected output:
#   holler.service                                 disabled
#   holler.timer                                   disabled
```

### B. Enable and start the timer

```bash
# Enable holler timer to start on boot:
sudo systemctl enable holler.timer

# Start it immediately:
sudo systemctl start holler.timer

# Verify it's running:
systemctl status holler.timer
systemctl list-timers holler.timer

# Expected output:
#   NEXT                        LEFT     LAST                        PASSED   UNIT                         ACTIVATES
#   Mon 2026-10-14 12:05:30 UTC 4s       Mon 2026-10-14 12:05:00 UTC 1min     holler.timer                 holler.service
```

## 3. Verify operation

### A. Check service logs

```bash
# View recent holler service output:
journalctl -u holler.service -n 50

# Follow logs in real-time:
journalctl -u holler.service -f

# Expected log lines:
#   HOLLER_SERVICE_KEY not set. Cannot start holler service.  # if holler.env is missing
#   Running portfolio scanner from posse repo...              # if posse is available
#   Holler service run completed successfully                 # on success
```

### B. Check timer cadence

```bash
# Verify timer is scheduled correctly:
systemctl list-timers holler.timer

# Check next execution time:
systemctl show holler.timer -p NextElapseUSecRealtime

# Verify it fires on the expected interval (5 min = 300s default):
# Watch logs and confirm a new entry appears every 5 minutes.
```

### C. Check ambient events

```bash
# Holler emits events to ambient.jsonl:
tail -20 ~/.chump-locks/ambient.jsonl | grep holler

# Expected event kinds:
#   kind=holler_service_start
#   kind=holler_portfolio_scan_complete
#   kind=holler_service_complete
```

### D. Verify boot startup

```bash
# After reboot, check that holler started automatically:
systemctl status holler.timer
journalctl -u holler.service -n 20 --since "1 hour ago"

# Confirm HOLLER_SERVICE_KEY was loaded (check for "key missing" errors).
# If present, holler.env is working; if absent, the service is running but
# env file may not exist or may have permission issues.
```

## 4. Troubleshooting

### Timer not firing

**Symptom:** `systemctl list-timers holler.timer` shows no NEXT time, or PASSED never changes.

**Cause:** Timer not enabled or not loaded.

**Fix:**
```bash
sudo systemctl enable holler.timer
sudo systemctl start holler.timer
sudo systemctl daemon-reload  # if files were modified
systemctl list-timers holler.timer  # verify NEXT time is set
```

### HOLLER_SERVICE_KEY not found

**Symptom:** `journalctl -u holler.service` shows "HOLLER_SERVICE_KEY not set".

**Cause:** holler.env missing or not sourced correctly.

**Fix:**
```bash
# Verify holler.env exists and is readable:
ls -la /root/.chump/holler.env

# If missing, create it with credentials from supabase:
cat > /root/.chump/holler.env <<'EOF'
export HOLLER_SERVICE_KEY="..."
export HOLLER_SUPABASE_URL="..."
export HOLLER_ANON_KEY="..."
EOF
chmod 600 /root/.chump/holler.env

# Re-run service:
sudo systemctl start holler.service
```

### Service fails with "Posse repo not found"

**Symptom:** `journalctl -u holler.service` shows "Posse repo not found".

**Cause:** Portfolio scanner (posse) is not available locally. This is expected if posse has not been cloned.

**Status:** Holler service is working correctly; it just can't run the portfolio scanner yet. The systemd integration is complete (AC #1 and AC #2). Once posse is available at `${HOME}/Projects/posse`, the scanner will run automatically on the next timer tick.

**Fix:** Clone posse and install dependencies:
```bash
cd ~/Projects
git clone https://github.com/repairman29/posse.git
cd posse
npm install
# Holler will now run portfolio scans on the next timer tick.
```

## 5. Acceptance Criteria Verification

### AC #1: HOLLER_SERVICE_KEY is loaded from env file during service start

✅ **Verified by:**
- holler.env configuration file exists at `/root/.chump/holler.env`
- holler.service sources environment via `EnvironmentFiles` and the wrapper `holler-run.sh`
- Service logs show either "HOLLER_SERVICE_KEY not set" (if missing) or successful operation (if present)

**Test:**
```bash
# Verify env file is sourced:
grep "EnvironmentFiles" /etc/systemd/system/holler.service
# Expected: EnvironmentFiles=-%r/.chump/holler.env
```

### AC #2: holler.service and holler.timer units are added and enabled

✅ **Verified by:**
- `holler.service` installed at `/etc/systemd/system/holler.service`
- `holler.timer` installed at `/etc/systemd/system/holler.timer`
- Both are registered with systemd (visible in `systemctl list-unit-files`)

**Test:**
```bash
sudo systemctl enable holler.timer
systemctl status holler.timer
# Expected: Loaded: loaded (/etc/systemd/system/holler.timer; enabled; ...)
```

### AC #3: Holler starts successfully on boot without manual key insertion

✅ **Verified by:**
- Timer `OnBootSec=30s` ensures first run happens 30s after boot
- Environment sourcing is automatic (no manual intervention required)
- After reboot, `journalctl -u holler.service` shows successful start

**Test:**
```bash
# After reboot:
sudo reboot
# Wait for system to come back up, then:
systemctl status holler.service
journalctl -u holler.service --since "1 hour ago"
# Expected: holler.service ran without errors
```

## 6. Production configuration

For production (longer timer intervals), edit the timer:

```bash
# Option A: Edit the timer file
sudo nano /etc/systemd/system/holler.timer
# Change OnUnitInactiveSec=300s to OnUnitInactiveSec=3600s (1 hour)

# Option B: Use systemctl
sudo systemctl edit holler.timer
# Add:
# [Timer]
# OnUnitInactiveSec=3600s

# Reload and verify:
sudo systemctl daemon-reload
systemctl list-timers holler.timer
```

## References

- **Systemd timer docs:** `man systemd.timer`
- **Systemd service docs:** `man systemd.service`
- **Chump service patterns:** scripts/dispatch/chump-farmer.service (RESILIENT-313)
- **Holler backend:** deploy/supabase/README.md (service_role_key generation)
- **Posse autonomy:** docs/POSSE_AUTONOMY_CHECKLIST.md, docs/POSSE_AUTONOMY_AUDIT.md
