#!/bin/bash
# ================================================================
#  NinjaOne Script — Revoke macOS Admin Access
#  Version  : 2.1
#  Platform : macOS 11 Big Sur and later
#  Run as   : System (root) — required
#
#  NinjaOne Parameters:
#    $1  USERNAME   (String, Required) — local account short name
#
#  What this script does:
#    1. Validates environment (root, macOS, OS version)
#    2. Validates the supplied username
#    3. Detects account type (local, mobile/AD-bound)
#    4. Last-admin safety guard — refuses to lock out the machine
#    5. Idempotency check — skips if not currently admin
#    6. Revokes admin via dseditgroup
#    7. Post-verification to confirm the change took effect
#    8. Updates NinjaOne custom field 'localadminrights'
#    9. Writes structured log to /var/log/ninja_admin_changes.log
#   10. Sends a macOS notification to the affected user (if logged in)
# ================================================================

# ── Colour codes (suppressed when not in a terminal) ─────────────
if [[ -t 1 ]]; then
    RED='\033[0;31m'; YELLOW='\033[1;33m'
    GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
else
    RED=''; YELLOW=''; GREEN=''; CYAN=''; NC=''
fi

# ── Constants ────────────────────────────────────────────────────
SCRIPT_NAME="ninja_remove_admin"
SCRIPT_VERSION="2.1"
LOG_FILE="/var/log/ninja_admin_changes.log"
MIN_MACOS_MAJOR=11
ACTION="REVOKE"
NINJA_CLI="/Applications/NinjaRMMAgent/programdata/ninjarmm-cli"
NINJA_FIELD="localadminrights"  # NinjaOne custom field name

# ── Logging helper ───────────────────────────────────────────────
log() {
    local LEVEL="$1"; shift
    local MESSAGE="$*"
    local TIMESTAMP
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    local HOSTNAME
    HOSTNAME=$(hostname -s)

    touch "$LOG_FILE" 2>/dev/null || true
    chmod 640 "$LOG_FILE" 2>/dev/null || true

    printf '%s | %-7s | %s | %s | %s\n' \
        "$TIMESTAMP" "$LEVEL" "$HOSTNAME" "$SCRIPT_NAME" "$MESSAGE" \
        | tee -a "$LOG_FILE"

    /usr/bin/logger -t "$SCRIPT_NAME" "[$LEVEL] $MESSAGE"
}

# ── Print banner ─────────────────────────────────────────────────
print_banner() {
    echo ""
    echo -e "${CYAN}=================================================${NC}"
    echo -e "${CYAN}  NinjaOne — macOS Admin Access Manager v${SCRIPT_VERSION}${NC}"
    echo -e "${CYAN}  Action  : REVOKE admin rights${NC}"
    echo -e "${CYAN}  Started : $(date '+%Y-%m-%d %H:%M:%S')${NC}"
    echo -e "${CYAN}=================================================${NC}"
    echo ""
}

# ── Exit handler ─────────────────────────────────────────────────
EXIT_CODE=0
trap 'log "INFO" "Script exited with code $EXIT_CODE"' EXIT

die() {
    local MSG="$1"
    log "ERROR" "$MSG"
    echo -e "${RED}✖  ERROR: $MSG${NC}" >&2
    EXIT_CODE=1
    exit 1
}

warn() {
    log "WARN" "$1"
    echo -e "${YELLOW}⚠  WARN:  $1${NC}"
}

success() {
    log "INFO" "$1"
    echo -e "${GREEN}✔  $1${NC}"
}

info() {
    log "INFO" "$1"
    echo -e "   $1"
}

# ================================================================
#  SECTION 1 — Environment checks
# ================================================================
print_banner
log "INFO" "Script started (version $SCRIPT_VERSION, action=$ACTION)"

if [[ $EUID -ne 0 ]]; then
    die "Script must run as root. Enable 'Run as system' in NinjaOne."
fi
info "Running as root ✓"

OS_TYPE=$(uname -s)
if [[ "$OS_TYPE" != "Darwin" ]]; then
    die "This script targets macOS only. Detected OS: $OS_TYPE"
fi
info "OS type: macOS ✓"

MACOS_VERSION=$(sw_vers -productVersion)
MACOS_MAJOR=$(echo "$MACOS_VERSION" | cut -d. -f1)
if (( MACOS_MAJOR < MIN_MACOS_MAJOR )); then
    die "Requires macOS $MIN_MACOS_MAJOR or later. Found: $MACOS_VERSION"
fi
info "macOS version: $MACOS_VERSION ✓"

for TOOL in dseditgroup dscl id sw_vers scutil launchctl; do
    if ! command -v "$TOOL" &>/dev/null; then
        die "Required tool not found: $TOOL"
    fi
done
info "Required tools present ✓"

# ================================================================
#  SECTION 2 — Parameter resolution
# ================================================================
echo ""
echo -e "${CYAN}── Parameters ───────────────────────────────────${NC}"

USERNAME="${1:-}"

if [[ -z "$USERNAME" || "$USERNAME" == --* ]]; then
    ARGS=("$@")
    for (( i=0; i<${#ARGS[@]}; i++ )); do
        if [[ "${ARGS[$i]}" == "--user" ]]; then
            USERNAME="${ARGS[$((i+1))]:-}"
        fi
    done
fi

if [[ -z "$USERNAME" ]]; then
    die "No username provided. Set a Script Parameter named USERNAME in NinjaOne."
fi

USERNAME=$(echo "$USERNAME" | tr -d '[:space:]')
if [[ "$USERNAME" =~ [^a-zA-Z0-9._-] ]]; then
    die "Username contains invalid characters: '$USERNAME'"
fi
if [[ ${#USERNAME} -gt 64 ]]; then
    die "Username too long (max 64 characters)."
fi

info "Target username : $USERNAME"
log "INFO" "Target username resolved: $USERNAME"

# ================================================================
#  SECTION 3 — User account validation
# ================================================================
echo ""
echo -e "${CYAN}── User Account Checks ──────────────────────────${NC}"

if ! id "$USERNAME" &>/dev/null; then
    die "User '$USERNAME' does not exist on this machine."
fi
info "User account exists ✓"

USER_UID=$(id -u "$USERNAME")
USER_GID=$(id -g "$USERNAME")
USER_REAL_NAME=$(dscl . -read "/Users/$USERNAME" RealName 2>/dev/null \
    | sed 's/RealName://' | xargs)
USER_HOME=$(dscl . -read "/Users/$USERNAME" NFSHomeDirectory 2>/dev/null \
    | awk '{print $2}')

info "UID            : $USER_UID"
info "GID            : $USER_GID"
info "Real name      : ${USER_REAL_NAME:-N/A}"
info "Home directory : ${USER_HOME:-N/A}"

# Never touch root
if (( USER_UID == 0 )); then
    die "Target user is root (UID 0). Cannot remove root from admin."
fi

# Block system accounts
if (( USER_UID < 500 )); then
    die "UID $USER_UID appears to be a system account. Refusing to modify."
fi
info "UID range check ✓ (UID $USER_UID is a standard user)"

ACCOUNT_TYPE="Local"
if dscl . -read "/Users/$USERNAME" OriginalNodeName &>/dev/null 2>&1; then
    ACCOUNT_TYPE="Mobile (AD/LDAP-cached)"
    warn "Mobile/AD-bound account detected. Change will apply to local admin group."
fi
info "Account type   : $ACCOUNT_TYPE"

# ================================================================
#  SECTION 4 — Last-admin safety guard
# ================================================================
echo ""
echo -e "${CYAN}── Admin Group Safety Check ─────────────────────${NC}"

CURRENT_MEMBERS=$(dscl . -read /Groups/admin GroupMembership 2>/dev/null || true)

# Count non-empty, non-label members
ADMIN_LIST=$(echo "$CURRENT_MEMBERS" \
    | tr ' ' '\n' \
    | grep -v '^GroupMembership:$' \
    | grep -v '^$' \
    | grep -v '^admin$')

ADMIN_COUNT=$(echo "$ADMIN_LIST" | grep -vc '^$' || echo 0)
info "Current admin members ($ADMIN_COUNT):"
echo "$ADMIN_LIST" | while read -r MEMBER; do
    [[ -n "$MEMBER" ]] && info "  - $MEMBER"
done

# Refuse if this is the only admin
if (( ADMIN_COUNT <= 1 )); then
    die "SAFETY BLOCK: '$USERNAME' appears to be the only admin account. Removing admin rights would lock out this machine. Assign another admin first."
fi

# Warn if removing would leave only one admin
if (( ADMIN_COUNT == 2 )); then
    warn "After removal, only ONE admin account will remain. Ensure that account is accessible."
fi

info "Admin count check ✓ ($ADMIN_COUNT admins — safe to proceed)"

# ================================================================
#  SECTION 5 — Idempotency check
# ================================================================
echo ""
echo -e "${CYAN}── Current Admin Status ─────────────────────────${NC}"

if ! echo "$CURRENT_MEMBERS" | grep -qw "$USERNAME"; then
    success "User '$USERNAME' is not in the admin group. No change required."
    EXIT_CODE=0
    exit 0
fi
info "User IS currently an admin — proceeding with removal."

# ================================================================
#  SECTION 6 — Revoke admin rights
# ================================================================
echo ""
echo -e "${CYAN}── Revoking Admin Rights ────────────────────────${NC}"
log "INFO" "Calling dseditgroup to remove '$USERNAME' from admin group"

DSEDIT_OUTPUT=$(/usr/sbin/dseditgroup -o edit -d "$USERNAME" -t user admin 2>&1)
DSEDIT_EXIT=$?

if [[ $DSEDIT_EXIT -ne 0 ]]; then
    log "ERROR" "dseditgroup output: $DSEDIT_OUTPUT"
    die "dseditgroup failed (exit $DSEDIT_EXIT). Output: $DSEDIT_OUTPUT"
fi

info "dseditgroup command succeeded."

# ================================================================
#  SECTION 7 — Post-action verification
# ================================================================
echo ""
echo -e "${CYAN}── Verification ─────────────────────────────────${NC}"

sleep 1

VERIFY=$(dscl . -read /Groups/admin GroupMembership 2>/dev/null || true)
if echo "$VERIFY" | grep -qw "$USERNAME"; then
    die "POST-VERIFY FAILED: '$USERNAME' still appears in admin group after dseditgroup ran."
else
    success "VERIFIED: '$USERNAME' is confirmed removed from the admin group."
    log "INFO" "ACTION=REVOKE STATUS=SUCCESS USER=$USERNAME UID=$USER_UID OS=$MACOS_VERSION TYPE=$ACCOUNT_TYPE"
fi

# ================================================================
#  SECTION 8 — Update NinjaOne custom field
# ================================================================
echo ""
echo -e "${CYAN}── NinjaOne Custom Field Update ─────────────────${NC}"

update_ninja_field() {
    # Confirm the current real-time admin status via dseditgroup checkmember
    if dseditgroup -o checkmember -m "$USERNAME" admin 2>/dev/null | grep -q "yes"; then
        ADMIN_STATUS="Yes"
    else
        ADMIN_STATUS="No"
    fi
    info "Resolved admin status for field: $ADMIN_STATUS"

    if [[ ! -f "$NINJA_CLI" ]]; then
        warn "NinjaOne CLI not found at '$NINJA_CLI'. Skipping custom field update."
        return
    fi

    if [[ ! -x "$NINJA_CLI" ]]; then
        warn "NinjaOne CLI is not executable. Skipping custom field update."
        return
    fi

    NINJA_OUTPUT=$("$NINJA_CLI" set "$NINJA_FIELD" "$ADMIN_STATUS" 2>&1)
    NINJA_EXIT=$?

    if [[ $NINJA_EXIT -eq 0 ]]; then
        success "NinjaOne field '$NINJA_FIELD' updated to '$ADMIN_STATUS'."
        log "INFO" "NINJA_FIELD=$NINJA_FIELD VALUE=$ADMIN_STATUS STATUS=OK"
    else
        warn "Failed to update NinjaOne field '$NINJA_FIELD'. Output: $NINJA_OUTPUT"
        log "WARN" "NINJA_FIELD=$NINJA_FIELD VALUE=$ADMIN_STATUS STATUS=FAILED OUTPUT=$NINJA_OUTPUT"
    fi
}

update_ninja_field

# ================================================================
#  SECTION 9 — Notify the user (best-effort, non-fatal)
# ================================================================
echo ""
echo -e "${CYAN}── User Notification ────────────────────────────${NC}"

CONSOLE_USER=$(scutil <<< "show State:/Users/ConsoleUser" \
    | awk '/Name :/ && !/loginwindow/ {print $3}' | head -1)

if [[ "$CONSOLE_USER" == "$USERNAME" ]]; then
    CONSOLE_UID=$(id -u "$CONSOLE_USER" 2>/dev/null || true)
    if [[ -n "$CONSOLE_UID" ]]; then
        launchctl asuser "$CONSOLE_UID" \
            osascript -e 'display notification "Your administrator access has been removed. Contact IT if you have questions." with title "IT Admin Change" subtitle "Access Updated"' \
            2>/dev/null \
            && info "Desktop notification sent to '$USERNAME'." \
            || warn "Could not send desktop notification (non-critical)."
    fi
else
    info "User '$USERNAME' is not at the console — skipping notification."
fi

# ================================================================
#  SECTION 10 — Final summary
# ================================================================
echo ""
echo -e "${CYAN}=================================================${NC}"
echo -e "${GREEN}  ✔  COMPLETE — Admin rights REVOKED${NC}"
echo -e "     User         : $USERNAME ($USER_REAL_NAME)"
echo -e "     UID          : $USER_UID"
echo -e "     Account type : $ACCOUNT_TYPE"
echo -e "     macOS        : $MACOS_VERSION"
echo -e "     Audit log    : $LOG_FILE"
echo -e "     Completed    : $(date '+%Y-%m-%d %H:%M:%S')"
echo -e "${CYAN}=================================================${NC}"
echo ""

EXIT_CODE=0
exit 0
