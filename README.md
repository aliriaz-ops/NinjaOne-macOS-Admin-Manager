# NinjaOne macOS Admin Manager

Bash scripts to **grant** and **revoke** local administrator rights on macOS endpoints, with logging, verification, NinjaOne custom field updates, and user notifications. Designed for macOS 11 Big Sur and later, and intended to run as **root** (system) via NinjaOne.

---

## Features

Both scripts are built for real-world RMM use:

- Run as root (system) and validate environment (macOS, OS version, required tools)
- Validate and sanitise the supplied username
- Detect account type (local vs mobile/AD-cached)
- Safe and idempotent admin changes using `dseditgroup` (Apple’s recommended tool) [web:78][web:81]
- Post‑action verification to confirm group membership changes
- Updates NinjaOne custom field `localadminrights` via `ninjarmm-cli`
- Structured audit logging to `/var/log/ninja_admin_changes.log`
- Best‑effort macOS notification to the affected user (if logged in at console)
- Safety guard in revoke script to avoid removing the last admin and locking out the machine

---

## Repository contents

- `ninja_add_admin.sh`  
  Grants local admin rights to a specified user and confirms the change.

- `ninja_remove_admin.sh`  
  Revokes local admin rights from a specified user, with safeguards to prevent lockout.

- `README.md`  
  This documentation.

- `LICENSE`  
  Project license (e.g. MIT).

---

## Requirements

- macOS 11 Big Sur or later (script checks `sw_vers` major version)  
- NinjaOne agent installed at:  
  `/Applications/NinjaRMMAgent/programdata/ninjarmm-cli` (for custom field updates)  
- Run script as **root** (`Run as system` in NinjaOne):
  - Grant script: `ninja_add_admin.sh`
  - Revoke script: `ninja_remove_admin.sh`
- Target user must already exist locally (`id $USERNAME` must succeed)  

---

## Parameters

Both scripts expect a **username** (short name) as the first argument:

- `USERNAME` (String, required) — local account short name on the Mac

### NinjaOne parameter mapping

In NinjaOne:

- Script parameter name: `USERNAME`
- Type: String
- Value: The short name of the macOS user (e.g. `jdoe`)

---

## Script: Grant macOS Admin Access (`ninja_add_admin.sh`)

### What it does

1. **Environment checks**
   - Confirms running as root.
   - Confirms OS is macOS (`Darwin`).
   - Ensures macOS version is 11+.
   - Checks for required tools: `dseditgroup`, `dscl`, `id`, `sw_vers`, `scutil`, `launchctl`.

2. **Parameter and user validation**
   - Resolves `USERNAME` from `$1` (or `--user` for local testing).
   - Strips whitespace; rejects unsafe characters and overly long names.
   - Confirms the user exists via `id`.
   - Gathers metadata: UID, GID, RealName, home directory, shell.
   - Blocks:
     - `root` (UID 0).
     - System/service accounts (UID < 500).
   - Detects account type:
     - Local vs mobile/AD-cached (`OriginalNodeName` via `dscl`).
   - Ensures account is not disabled.

3. **Idempotency**
   - Reads current `admin` group membership via `dscl`.
   - If the user is already an admin, exits cleanly with a “no change required” message.

4. **Grant admin rights**
   - Calls:
     - `/usr/sbin/dseditgroup -o edit -a "$USERNAME" -t user admin`
   - Logs dseditgroup output and exit code.

5. **Verification**
   - Re-reads the `admin` group.
   - Confirms the user is now present.
   - Logs success with structured fields: `ACTION=GRANT`, `STATUS=SUCCESS`, `USER`, `UID`, `OS`, `TYPE`.

6. **NinjaOne custom field**
   - Uses `dseditgroup -o checkmember` to resolve current admin status (`Yes` / `No`).
   - Updates the NinjaOne custom field `localadminrights` via `ninjarmm-cli set localadminrights <Yes|No>`.
   - Logs success or failure of the field update.

7. **User notification**
   - Determines console user via `scutil show State:/Users/ConsoleUser`.
   - If the console user matches `USERNAME`, uses `launchctl asuser` and `osascript` to display a notification:
     - “Your account has been granted administrator access…”

8. **Final summary**
   - Prints a clear summary of the change (user, UID, account type, macOS version, log file).

---

## Script: Revoke macOS Admin Access (`ninja_remove_admin.sh`)

### What it does

1. **Environment checks**
   - Same root/macOS/OS version/tool checks as the grant script.

2. **Parameter and user validation**
   - Same username resolution and sanitisation.
   - Confirms user exists.
   - Gathers UID, GID, RealName, home directory.
   - Blocks:
     - `root` (UID 0).
     - System accounts (UID < 500).
   - Detects account type (local vs mobile/AD-cached).

3. **Last-admin safety guard**
   - Reads current `admin` group membership via `dscl`.
   - Counts non-empty members (excluding `GroupMembership:` label and bare `admin` token).
   - Refuses to proceed if:
     - The target user appears to be the **only** admin (`ADMIN_COUNT <= 1`).
       - Logs and exits to avoid locking out the machine.
   - Warns if removal will leave only one remaining admin.

4. **Idempotency**
   - If the user is **not** in the `admin` group, exits with “no change required”.

5. **Revoke admin rights**
   - Calls:
     - `/usr/sbin/dseditgroup -o edit -d "$USERNAME" -t user admin`
   - Logs dseditgroup output and exit code.

6. **Verification**
   - Re-reads the `admin` group.
   - Confirms the user is no longer present.
   - Logs success with structured fields: `ACTION=REVOKE`, `STATUS=SUCCESS`, `USER`, `UID`, `OS`, `TYPE`.

7. **NinjaOne custom field**
   - Same `dseditgroup -o checkmember` logic to calculate `Yes`/`No`.
   - Updates `localadminrights` via `ninjarmm-cli` and logs the result.

8. **User notification**
   - Uses console user detection and `osascript` to show a notification:
     - “Your administrator access has been removed…”

9. **Final summary**
   - Prints a summary with user info and the path to the audit log.

---

## Logging and audit trail

Both scripts log to:

- **File**: `/var/log/ninja_admin_changes.log`  
- **Format** (one line per event):

  ```text
  YYYY-MM-DD HH:MM:SS | LEVEL   | HOSTNAME | SCRIPT_NAME | MESSAGE
  ```

- Messages include:
  - Script start/exit.
  - Environment validation.
  - Actions and results for `dseditgroup`.
  - NinjaOne custom field updates.
  - Safety guard decisions and verification outcomes.

Additionally:

- `logger` is used to write into the macOS unified log (`Console.app`), tagged with the script name.

---

## NinjaOne integration

### Grant admin (ninja_add_admin.sh)

- **Script name in NinjaOne**: `macOS — Grant Local Admin via dseditgroup`
- **Run as**: System (root)
- **Parameter**:
  - `USERNAME` → short name of macOS user (e.g. `jdoe`)

Example NinjaOne script command:

```bash
#!/bin/bash
./ninja_add_admin.sh "$USERNAME"
```

### Revoke admin (ninja_remove_admin.sh)

- **Script name in NinjaOne**: `macOS — Revoke Local Admin via dseditgroup`
- **Run as**: System (root)
- **Parameter**:
  - `USERNAME` → short name of macOS user to demote

Example NinjaOne script command:

```bash
#!/bin/bash
./ninja_remove_admin.sh "$USERNAME"
```

---

## Usage examples (local testing)

From a root shell on the Mac (for testing outside NinjaOne):

```bash
# Grant admin rights to user 'jdoe'
sudo ./ninja_add_admin.sh jdoe

# Revoke admin rights from user 'jdoe'
sudo ./ninja_remove_admin.sh jdoe
```

For testing with the `--user` flag:

```bash
sudo ./ninja_add_admin.sh --user jdoe
sudo ./ninja_remove_admin.sh --user jdoe
```

---

## Safety and best practices

- Always ensure there is at least one known good admin account on each machine (e.g. a break‑glass IT admin).
- Use the **revoke** script as part of a just‑in‑time access workflow:
  - Grant admin for a time‑boxed window via policy or script.
  - Revoke admin when the task is complete.
- Track the `localadminrights` custom field in NinjaOne as a single source of truth for local admin status on macOS endpoints [web:82].

---

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.