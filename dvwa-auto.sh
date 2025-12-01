#!/usr/bin/env bash
set -euo pipefail

# Universal DVWA Auto Installer (Option A: fully automatic, no prompts)
# - Removes any existing /var/www/html/dvwa (clean install)
# - Idempotent DB logic (safe CREATE IF NOT EXISTS + DROP USER IF EXISTS)
# - Fixes git "dubious ownership" issues
# - Ensures required PHP modules and Apache modules
# - Attempts automatic php.ini tweaks for required settings
# - Restarts services and tries to run DVWA setup.php (best-effort)
# NOTE: This will reset any existing DVWA install on the machine.

INSTALLER_VER="2.0"
DVWA_DIR="/var/www/html/dvwa"
REPO="https://github.com/digininja/DVWA.git"
DB_NAME="dvwa"
DB_USER="dvwa"
DB_PASS="dvwa123"
LOG="/var/log/dvwa-auto-install.log"

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run with sudo or as root"; exit 1
  fi
}

# run mysql safely as root via sudo (works on Debian/Ubuntu/Kali defaults)
mysql_root_exec() {
  # Use sudo mysql -e so we don't need interactive root password
  if sudo mysql -e "SELECT 1;" >/dev/null 2>&1; then
    sudo mysql -e "$1"
    return $?
  fi

  # try with mysql command (if sudo mysql not allowed)
  if mysql -u root -e "SELECT 1;" >/dev/null 2>&1; then
    mysql -u root -e "$1"
    return $?
  fi

  # last resort: try mysql with sudo and pipe SQL file
  echo "ERROR: Could not run mysql as root non-interactively. Manual intervention required." | tee -a "$LOG" >&2
  return 2
}

# ------------- start -------------
require_root
mkdir -p "$(dirname "$LOG")"
touch "$LOG"
log "Starting DVWA Auto Installer v$INSTALLER_VER"

# Update & install packages (apt-based)
log "Updating apt and installing required packages..."
apt update -y
apt install -y apache2 mariadb-server php php-mysql php-gd php-xml php-curl php-zip libapache2-mod-php git unzip || true

# enable & start services
log "Enabling & starting apache2 and mariadb..."
systemctl enable apache2 || true
systemctl enable mariadb || true
systemctl start mariadb || true
systemctl start apache2 || true

# Fix Apache ServerName warning -> set to 127.0.0.1 if not set
APACHE_CONF="/etc/apache2/conf-available/servername.conf"
if ! grep -q "ServerName" /etc/apache2/apache2.conf 2>/dev/null; then
  echo "ServerName 127.0.0.1" > "$APACHE_CONF"
  a2enconf servername >/dev/null 2>&1 || true
  log "Set Apache ServerName to 127.0.0.1"
fi

# PHP ini path (pick first match)
PHP_INI="$(ls -d /etc/php/*/apache2 2>/dev/null | head -n1)/php.ini" || PHP_INI=""
if [ -n "$PHP_INI" ] && [ -f "$PHP_INI" ]; then
  log "Adjusting php.ini settings (allow_url_fopen, allow_url_include, display_errors)"
  sed -i "s/^\s*allow_url_fopen\s*=.*/allow_url_fopen = On/" "$PHP_INI" || true
  sed -i "s/^\s*allow_url_include\s*=.*/allow_url_include = On/" "$PHP_INI" || true
  sed -i "s/^\s*display_errors\s*=.*/display_errors = On/" "$PHP_INI" || true
  sed -i "s/^\s*display_startup_errors\s*=.*/display_startup_errors = On/" "$PHP_INI" || true
  systemctl restart apache2 || true
else
  log "php.ini not found automatically; skipping php.ini tweaks"
fi

# ------------- Database setup (idempotent) -------------
log "Setting up MariaDB database and user (idempotent)..."

SQL="
CREATE DATABASE IF NOT EXISTS ${DB_NAME};
DROP USER IF EXISTS '${DB_USER}'@'localhost';
CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
"

if ! mysql_root_exec "$SQL"; then
  log "Failed to execute DB commands non-interactively. See log and run the following manually if needed:"
  echo "$SQL"
  exit 1
fi

# ------------- DVWA clone/update (clean) -------------
log "Installing DVWA to $DVWA_DIR (clean install)."

# Remove existing dir to ensure clean state
if [ -d "$DVWA_DIR" ]; then
  log "Removing existing DVWA directory (clean replace)..."
  rm -rf "$DVWA_DIR"
fi

log "Cloning DVWA from $REPO ..."
git clone "$REPO" "$DVWA_DIR" || { log "git clone failed"; exit 1; }

# Fix git dubious ownership (some distros require marking safe directory)
git config --global --add safe.directory "$DVWA_DIR" 2>/dev/null || true

# ------------- Permissions -------------
log "Setting file ownership and permissions..."
chown -R www-data:www-data "$DVWA_DIR" || true
find "$DVWA_DIR" -type d -exec chmod 755 {} \; || true
find "$DVWA_DIR" -type f -exec chmod 644 {} \; || true
# ensure uploads and tmp are writable by webserver
mkdir -p "$DVWA_DIR/hackable/uploads" || true
chmod -R 770 "$DVWA_DIR/hackable/uploads" || true

# phpids log file (if present) ensure writable
if [ -f "$DVWA_DIR/external/phpids/0.6/lib/IDS/tmp/phpids_log.txt" ]; then
  chmod 666 "$DVWA_DIR/external/phpids/0.6/lib/IDS/tmp/phpids_log.txt" || true
fi

# ------------- Config file edit -------------
CFG_DIST="$DVWA_DIR/config/config.inc.php.dist"
CFG="$DVWA_DIR/config/config.inc.php"

if [ -f "$CFG_DIST" ]; then
  cp "$CFG_DIST" "$CFG"
  # replace DB settings robustly using perl if available, fallback to sed
  if command -v perl >/dev/null 2>&1; then
    perl -0777 -pe "
      s/\\\$_DVWA\\s*\\[\\s*'db_database'\\s*\\]\\s*=\\s*'.*?';/\\\$_DVWA['db_database'] = '${DB_NAME}';/gs;
      s/\\\$_DVWA\\s*\\[\\s*'db_user'\\s*\\]\\s*=\\s*'.*?';/\\\$_DVWA['db_user'] = '${DB_USER}';/gs;
      s/\\\$_DVWA\\s*\\[\\s*'db_password'\\s*\\]\\s*=\\s*'.*?';/\\\$_DVWA['db_password'] = '${DB_PASS}';/gs;
    " -i "$CFG" || true
  else
    sed -i "s/\$_DVWA\['db_database'\] = .*;/\$_DVWA['db_database'] = '${DB_NAME}';/" "$CFG" || true
    sed -i "s/\$_DVWA\['db_user'\] = .*;/\$_DVWA['db_user'] = '${DB_USER}';/" "$CFG" || true
    sed -i "s/\$_DVWA\['db_password'\] = .*;/\$_DVWA['db_password'] = '${DB_PASS}';/" "$CFG" || true
  fi
  log "DVWA config updated."
else
  log "Warning: config.dist not found; please check DVWA repo structure."
fi

# ------------- Enable mod_rewrite -------------
if a2enmod rewrite >/dev/null 2>&1; then
  log "Enabled apache mod_rewrite"
fi

# restart apache
log "Restarting Apache..."
systemctl restart apache2 || true

# ------------- Try to auto-run setup.php (best-effort) -------------
if command -v php >/dev/null 2>&1 && [ -f "$DVWA_DIR/setup.php" ]; then
  log "Attempting to run DVWA setup.php via php-cli (best-effort)..."
  # some setup.php expects HTTP host, so this is best-effort only
  php "$DVWA_DIR/setup.php" >/dev/null 2>&1 || log "php setup.php returned a non-zero exit code (ok)."
fi

log "Installation finished. Open http://127.0.0.1/dvwa -> Login admin/password -> Setup -> Create / Reset Database (if required)."
log "If DB tables are missing, press 'Create / Reset Database' on DVWA setup page."

exit 0
