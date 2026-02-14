#!/bin/bash
# ============================================================
#  🫀⚡ Agent Defibrillator
#  
#  A watchdog script that monitors your AI agent gateway and
#  automatically revives it when it flatlines.
#
#  https://github.com/hazy2go/agent-defibrillator
# ============================================================

set -euo pipefail

# ============================================================
# Configuration (edit these or set via environment variables)
# ============================================================

# Gateway service label (find yours with: launchctl list | grep -i openclaw)
GATEWAY_LABEL="${DEFIB_GATEWAY_LABEL:-ai.openclaw.gateway}"

# Path to gateway plist
GATEWAY_PLIST="${DEFIB_GATEWAY_PLIST:-$HOME/Library/LaunchAgents/${GATEWAY_LABEL}.plist}"

# Process name to check (what shows up in `ps aux`)
GATEWAY_PROCESS="${DEFIB_GATEWAY_PROCESS:-openclaw-gateway}"

# Log file location
LOG_DIR="${DEFIB_LOG_DIR:-$HOME/.openclaw/logs}"
LOG_FILE="${LOG_DIR}/defibrillator.log"

# Timing settings
RETRY_DELAY="${DEFIB_RETRY_DELAY:-10}"       # Seconds between health check retries
MAX_RETRIES="${DEFIB_MAX_RETRIES:-3}"        # Retries before declaring death
COOLDOWN_SECONDS="${DEFIB_COOLDOWN:-300}"    # Cooldown between restarts (5 min)

# State files
LOCKFILE="/tmp/agent-defibrillator.lock"
COOLDOWN_FILE="/tmp/agent-defibrillator-cooldown"

# ============================================================
# Functions
# ============================================================

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [defib] $1" >> "$LOG_FILE"
}

log_and_echo() {
    log "$1"
    echo "$1"
}

rotate_log() {
    if [ -f "$LOG_FILE" ] && [ "$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)" -gt 102400 ]; then
        mv "$LOG_FILE" "$LOG_FILE.old"
    fi
}

check_process() {
    # Use ps + grep (more reliable than pgrep on macOS)
    ps aux 2>/dev/null | grep -q "[${GATEWAY_PROCESS:0:1}]${GATEWAY_PROCESS:1}"
}

restart_gateway() {
    log "🫀⚡ SHOCKING! Attempting to revive gateway..."

    # Method 1: Try launchctl kickstart (cleanest)
    if launchctl kickstart -k "gui/$(id -u)/$GATEWAY_LABEL" 2>> "$LOG_FILE"; then
        sleep 10
        if check_process; then
            log "✅ PULSE RESTORED via kickstart!"
            date +%s > "$COOLDOWN_FILE"
            return 0
        fi
    fi

    # Method 2: Fallback to bootout/bootstrap
    log "⚠️ Kickstart failed, trying bootout/bootstrap..."
    
    launchctl bootout "gui/$(id -u)/$GATEWAY_LABEL" 2>> "$LOG_FILE" || true
    sleep 3

    # Kill any orphaned processes
    ORPHAN_PIDS=$(ps aux 2>/dev/null | grep "[${GATEWAY_PROCESS:0:1}]${GATEWAY_PROCESS:1}" | awk '{print $2}')
    if [ -n "$ORPHAN_PIDS" ]; then
        log "🔪 Killing orphaned processes: $ORPHAN_PIDS"
        echo "$ORPHAN_PIDS" | xargs kill -9 2>/dev/null || true
        sleep 2
    fi

    # Bootstrap back up
    if [ -f "$GATEWAY_PLIST" ]; then
        launchctl bootstrap "gui/$(id -u)" "$GATEWAY_PLIST" 2>> "$LOG_FILE"
        sleep 10
        
        if check_process; then
            log "✅ PULSE RESTORED via bootstrap!"
            date +%s > "$COOLDOWN_FILE"
            return 0
        fi
    else
        log "❌ Gateway plist not found at: $GATEWAY_PLIST"
    fi

    log "💀 FLATLINE - Could not revive gateway. Manual intervention needed."
    date +%s > "$COOLDOWN_FILE"
    return 1
}

# ============================================================
# Main
# ============================================================

mkdir -p "$LOG_DIR"
rotate_log

# Prevent concurrent runs
if [ -f "$LOCKFILE" ]; then
    LOCK_PID=$(cat "$LOCKFILE" 2>/dev/null)
    if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
        exit 0  # Another instance running
    fi
    rm -f "$LOCKFILE"
fi
echo $$ > "$LOCKFILE"
trap 'rm -f "$LOCKFILE"' EXIT

# Check cooldown
if [ -f "$COOLDOWN_FILE" ]; then
    LAST_RESTART=$(cat "$COOLDOWN_FILE" 2>/dev/null || echo 0)
    NOW=$(date +%s)
    ELAPSED=$((NOW - LAST_RESTART))
    if [ "$ELAPSED" -lt "$COOLDOWN_SECONDS" ]; then
        exit 0  # Still in cooldown
    fi
fi

# Quick health check
if check_process; then
    # Touch log file so dashboards can track lastRun
    touch "$LOG_FILE"
    exit 0
fi

# Process not found - start emergency protocol
log "🚨 CARDIAC ARREST DETECTED! Gateway process not found."

# Retry loop
ATTEMPT=1
while [ "$ATTEMPT" -le "$MAX_RETRIES" ]; do
    log "💓 Checking for pulse... attempt $ATTEMPT/$MAX_RETRIES"
    sleep "$RETRY_DELAY"
    
    if check_process; then
        log "😮‍💨 False alarm - gateway recovered on its own"
        exit 0
    fi
    
    ATTEMPT=$((ATTEMPT + 1))
done

# All retries exhausted - time to shock
log "☠️ No pulse after $MAX_RETRIES checks. CLEAR! 🫀⚡"
restart_gateway
exit $?
