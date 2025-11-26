#!/usr/bin/env bash
#
# dvwa-auto.sh -- Universal DVWA auto-installer (idempotent + versioned)
#
# Usage:
#   sudo bash dvwa-auto.sh            # run normally
#   sudo bash dvwa-auto.sh --dry-run  # show actions without changing system
#   sudo bash dvwa-auto.sh --uninstall  # remove dvwa files + DB user+db (careful)
#
# After editing locally, update GitHub (git add/commit/push). Your raw URL will always
# serve the latest script; your TinyURL will redirect to the latest raw content.
#
set -euo pipefail

# --------------------------
# CONFIG / VERSION
# --------------------------
SCRIPT_VERSION="1.0.0"
LOGFILE="/var/log/dvwa-installer.log"
INSTALL_DIR="/var/www/html/dvwa"
REPO_URL="https://github.com/digininja/DVWA.git"
DB_NAME="dvwa"
DB_USER="dvwa"
DB_PASS="dvwa123"
VERSION_FILE="/usr/local/dvwa_installer_version"
DRY_RUN=0
UNINSTALL=0

# --------------------------
# Helpers
# --------------------------
log() {
    echo "[$(date '+%F %T')] $*" | tee -a "$LOGFILE"
}
err() {
    echo "ERROR: $*" | tee -a "$LOGFILE" >&2
}

usage() {
    cat <<EOF
dvwa-auto.sh - version $SCRIPT_VERSION
Usage:
  sudo bash dvwa-auto.sh            # install/update DVWA
  sudo bash dvwa-auto.sh --dry-run  # don't change system
  sudo bash dvwa-auto.sh --uninstall # remove DVWA and DB (destructive)

EOF
    exit 1
}

# parse args
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --uninstall) UNINSTALL=1 ;;
        --help|-h) usage ;;
        *) ;;
    esac
done

run_or_echo() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[DRY-RUN] $*"
    else
        log "$*"
        eval "$@"
    fi
}

# ensure running as root
if [ "$(id -u)" -ne 0 ]; then
    err "Please run as root (sudo)."
    exit 1
fi

# create log file if missing
touch "$LOGFILE"
chmod 644 "$LOGFILE"

# --------------------------
# Uninstall path
# --------------------------
if [ "$UNINSTALL" -eq 1 ]; then
    read -p "This will DELETE DVWA files and DROP database/user. Are you sure? (yes/NO): " CONF
    if [ "$CONF" != "yes" ]; then
        log "Uninstall cancelled by user."
        exit 0
    fi

    log "Stopping apache and mariadb services (if running)..."
    run_or_echo "systemctl stop apache2 || true"
    run_or_echo "systemctl stop mariadb || true"

    if [ -d "$INSTALL_DIR" ]; then
        log "Removing DVWA directory: $INSTALL_DIR"
        run_or_echo "rm -rf \"$INSTALL_DIR\""
    else
        log "DVWA directory not found; skipping removal."
    fi

    # Drop DB and user safely
    log "Dropping database and user (if exist)..."
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[DRY-RUN] mysql -e \"DROP DATABASE IF EXISTS $DB_NAME; DROP USER IF EXISTS '$DB_USER'@'localhost'; FLUSH PRIVILEGES;\""
    else
        mysql -u root -e "DROP DATABASE IF EXISTS $DB_NAME; DROP USER IF EXISTS '$DB_USER'@'localhost'; FLUSH PRIVILEGES;" || {
            err "Failed to drop DB/user (check MariaDB root access)."
        }
    fi

    log "Removing version file if present: $VERSION_FILE"
    run_or_echo "rm -f \"$VERSION_FILE\""

    log "Uninstall complete."
    exit 0
fi

# --------------------------
# Version check (avoid re-running full setup)
# --------------------------
if [ -f "$VERSION_FILE" ]; then
    INSTALLED_VERSION="$(cat "$VERSION_FILE" 2>/dev/null || echo '')"
    if [ "$INSTALLED_VERSION" = "$SCRIPT_VERSION" ]; then
        log "Installer version $SCRIPT_VERSION already recorded on this machine."

        # If DVWA directory exists, do a lightweight update (git pull)
        if [ -d "$INSTALL_DIR/.git" ]; then
            log "DVWA appears installed; running lightweight update (git pull)."
            if [ "$DRY_RUN" -eq 1 ]; then
                echo "[DRY-RUN] cd \"$INSTALL_DIR\" && git pull --rebase"
            else
                cd "$INSTALL_DIR"
                git pull --rebase || log "git pull returned non-zero (ok to continue)."
            fi
        else
            log "DVWA directory not found. Running full install."
        fi
        # exit (no full install) — but if user wants always to re-run full flow, remove this exit
        log "No further action required. Exiting."
        exit 0
    else
        log "Installed script version ($INSTALLED_VERSION) differs from current ($SCRIPT_VERSION). Continuing to run installer."
    fi
fi

# --------------------------
# 1) System update + packages
# --------------------------
log "[+] Updating apt cache and installing packages..."
PKGS="apache2 mariadb-server php php-mysql php-gd php-xml php-curl php-zip libapache2-mod-php git unzip"
run_or_echo "apt update -y"
run_or_echo "apt install -y $PKGS"

run_or_echo "systemctl enable apache2 || true"
run_or_echo "systemctl enable mariadb || true"
run_or_echo "systemctl start apache2 || true"
run_or_echo "systemctl start mariadb || true"

# --------------------------
# 2) Database: safe create & user reset
# --------------------------
log "[+] Setting up MariaDB database and user (idempotent)..."

SQLCMD="CREATE DATABASE IF NOT EXISTS ${DB_NAME}; \
DROP USER IF EXISTS '${DB_USER}'@'localhost'; \
CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}'; \
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost'; \
FLUSH PRIVILEGES;"

if [ "$DRY_RUN" -eq 1 ]; then
    echo "[DRY-RUN] mysql -u root -e \"$SQLCMD\""
else
    # run as root (no password). If your MariaDB root requires password, user should run with sudo mysql -u root -p or configure rootless access
    mysql -u root -e "$SQLCMD" || {
        err "Could not run MySQL commands as root. If your MariaDB root user requires a password, you must configure rootless access or run manual DB steps."
    }
fi

# --------------------------
# 3) Clone or update DVWA
# --------------------------
log "[+] Installing or updating DVWA in $INSTALL_DIR"

if [ -d "$INSTALL_DIR/.git" ]; then
    log "DVWA repo exists — pulling latest changes."
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[DRY-RUN] cd \"$INSTALL_DIR\" && git pull --rebase"
    else
        cd "$INSTALL_DIR"
        git pull --rebase || log "git pull returned non-zero (ok to continue)."
    fi
else
    # ensure parent has correct permissions
    run_or_echo "rm -rf \"$INSTALL_DIR\""   # remove stale dir if present
    run_or_echo "git clone \"$REPO_URL\" \"$INSTALL_DIR\""
fi

# ensure webroot ownership & permissions
run_or_echo "chown -R www-data:www-data \"$INSTALL_DIR\" || true"
run_or_echo "find \"$INSTALL_DIR\" -type d -exec chmod 755 {} \\;"
run_or_echo "find \"$INSTALL_DIR\" -type f -exec chmod 644 {} \\;"
# keep upload dirs writable by webserver
run_or_echo "chmod -R 770 \"$INSTALL_DIR\"/hackable/uploads || true"

# --------------------------
# 4) Configure DVWA config file
# --------------------------
CFG_DIR="$INSTALL_DIR/config"
CFG_DIST="$CFG_DIR/config.inc.php.dist"
CFG="$CFG_DIR/config.inc.php"

log "[+] Preparing DVWA config ($CFG)"

if [ ! -f "$CFG_DIST" ]; then
    err "Expected $CFG_DIST not found. Check DVWA repo structure."
else
    if [ ! -f "$CFG" ]; then
        run_or_echo "cp \"$CFG_DIST\" \"$CFG\""
    else
        # keep a backup of existing config
        TIMESTAMP="$(date +%s)"
        run_or_echo "cp \"$CFG\" \"$CFG.bak.$TIMESTAMP\""
    fi

    # Replace DB settings in config file reliably using perl (handles spacing)
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[DRY-RUN] updating db settings in $CFG: DB_NAME=$DB_NAME DB_USER=$DB_USER DB_PASS=$DB_PASS"
    else
        # Use perl to replace lines that set $_DVWA[...] values
        perl -0777 -pe "
            s/\\\$_DVWA\\s*\\[\\s*'db_database'\\s*\\]\\s*=\\s*'.*?';/\\\$_DVWA['db_database'] = '${DB_NAME}';/gs;
            s/\\\$_DVWA\\s*\\[\\s*'db_user'\\s*\\]\\s*=\\s*'.*?';/\\\$_DVWA['db_user'] = '${DB_USER}';/gs;
            s/\\\$_DVWA\\s*\\[\\s*'db_password'\\s*\\]\\s*=\\s*'.*?';/\\\$_DVWA['db_password'] = '${DB_PASS}';/gs;
        " -i "$CFG" || err "Failed to update $CFG using perl."
    fi
fi

# --------------------------
# 5) Restart webserver and set final perms
# --------------------------
log "[+] Adjusting permissions and restarting Apache..."
run_or_echo "chown -R www-data:www-data \"$INSTALL_DIR\" || true"
run_or_echo "systemctl restart apache2 || true"

# --------------------------
# 6) Create/Reset DVWA DB tables (optional manual step)
# --------------------------
log "[+] NOTE: You may still need to run DVWA's in-browser 'Create / Reset Database' step."
log "     Visit http://127.0.0.1/dvwa -> Login (admin / password) -> Setup -> Create / Reset Database"

# but attempt to run DVWA setup SQL automatically (best-effort)
SETUP_PHP="$INSTALL_DIR/external/phpids/0.6/lib/IDS/Log/Email.php" # dummy check to ensure repo is present

if [ -f "$INSTALL_DIR/setup.php" ]; then
    # Many DVWA versions ship a setup.php that triggers DB creation.
    # We'll attempt a best-effort to invoke it via php-cli but it's safer to run from browser.
    if command -v php >/dev/null 2>&1; then
        log "[+] Attempting to run DVWA setup.php via php-cli (best-effort)."
        if [ "$DRY_RUN" -eq 1 ]; then
            echo "[DRY-RUN] php \"$INSTALL_DIR/setup.php\""
        else
            php "$INSTALL_DIR/setup.php" || log "php setup.php returned non-zero (ok). If DB tables missing, use web Setup page."
        fi
    fi
fi

# --------------------------
# 7) Write installed version marker
# --------------------------
if [ "$DRY_RUN" -eq 1 ]; then
    echo "[DRY-RUN] echo \"$SCRIPT_VERSION\" > \"$VERSION_FILE\""
else
    echo "$SCRIPT_VERSION" > "$VERSION_FILE"
    chmod 644 "$VERSION_FILE"
fi

log "[+] DONE! DVWA installed/updated at: $INSTALL_DIR"
exit 0
