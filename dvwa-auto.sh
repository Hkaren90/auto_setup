#!/usr/bin/env bash
set -euo pipefail

INSTALLER_VER="3.0"
DVWA_DIR="/var/www/html/dvwa"
REPO="https://github.com/digininja/DVWA.git"
DB_NAME="dvwa"
DB_USER="dvwa"
DB_PASS="dvwa123"
LOG="/var/log/dvwa-auto-install.log"

log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

require_root(){ [ "$(id -u)" -ne 0 ] && echo "Run with sudo" && exit 1; }

mysql_exec(){ sudo mysql -e "$1" 2>/dev/null || mysql -u root -e "$1" 2>/dev/null; }

install_packages(){
  apt update -y
  apt install -y apache2 mariadb-server php php-mysql php-gd php-xml php-curl php-zip php-mbstring libapache2-mod-php git unzip curl || true
  REQUIRED_PHP=("gd" "mysqli" "curl" "xml" "mbstring" "zip")
  for ext in "${REQUIRED_PHP[@]}"; do
    php -m | grep -qi "$ext" || apt install -y "php-$ext" || true
  done
  systemctl enable --now apache2 mariadb || true
}

fix_apache_php(){
  APACHE_CONF="/etc/apache2/conf-available/servername.conf"
  grep -q "ServerName" /etc/apache2/apache2.conf || { echo "ServerName 127.0.0.1" >"$APACHE_CONF"; a2enconf servername >/dev/null 2>&1; }
  PHP_INI="$(ls -d /etc/php/*/apache2 2>/dev/null | head -n1)/php.ini"
  [ -f "$PHP_INI" ] && sed -i "s/^\s*allow_url_fopen\s*=.*/allow_url_fopen = On/;s/^\s*allow_url_include\s*=.*/allow_url_include = On/;s/^\s*display_errors\s*=.*/display_errors = On/;s/^\s*display_startup_errors\s*=.*/display_startup_errors = On/" "$PHP_INI" && systemctl restart apache2 || true
}

setup_database(){
  SQL="CREATE DATABASE IF NOT EXISTS $DB_NAME; DROP USER IF EXISTS '$DB_USER'@'localhost'; CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS'; GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost'; FLUSH PRIVILEGES;"
  mysql_exec "$SQL" || { log "DB setup failed"; exit 1; }
}

clone_dvwa(){
  [ -d "$DVWA_DIR" ] && rm -rf "$DVWA_DIR"
  git clone "$REPO" "$DVWA_DIR" || { log "git clone failed"; exit 1; }
  git config --global --add safe.directory "$DVWA_DIR" 2>/dev/null || true
}

fix_permissions(){
  chown -R www-data:www-data "$DVWA_DIR"
  find "$DVWA_DIR" -type d -exec chmod 755 {} \;
  find "$DVWA_DIR" -type f -exec chmod 644 {} \;
  mkdir -p "$DVWA_DIR/hackable/uploads"
  chmod -R 770 "$DVWA_DIR/hackable/uploads"
  [ -f "$DVWA_DIR/external/phpids/0.6/lib/IDS/tmp/phpids_log.txt" ] && chmod 666 "$DVWA_DIR/external/phpids/0.6/lib/IDS/tmp/phpids_log.txt"
}

update_config(){
  CFG_DIST="$DVWA_DIR/config/config.inc.php.dist"
  CFG="$DVWA_DIR/config/config.inc.php"
  [ -f "$CFG_DIST" ] && cp "$CFG_DIST" "$CFG"
  command -v perl >/dev/null 2>&1 && perl -0777 -pe "
    s/\\\$_DVWA\\s*\\['db_database'\\]\\s*=.*;/\\\$_DVWA['db_database'] = '$DB_NAME';/gs;
    s/\\\$_DVWA\\s*\\['db_user'\\]\\s*=.*;/\\\$_DVWA['db_user'] = '$DB_USER';/gs;
    s/\\\$_DVWA\\s*\\['db_password'\\]\\s*=.*;/\\\$_DVWA['db_password'] = '$DB_PASS';/gs;" -i "$CFG" || sed -i "s/\$_DVWA\['db_database'\] = .*;/\$_DVWA['db_database'] = '$DB_NAME';/; s/\$_DVWA\['db_user'\] = .*;/\$_DVWA['db_user'] = '$DB_USER';/; s/\$_DVWA\['db_password'\] = .*;/\$_DVWA['db_password'] = '$DB_PASS';/" "$CFG"
}

final_steps(){
  a2enmod rewrite >/dev/null 2>&1
  systemctl restart apache2
  [ -f "$DVWA_DIR/setup.php" ] && php "$DVWA_DIR/setup.php" >/dev/null 2>&1 || true
  log "DVWA installed. Visit http://127.0.0.1/dvwa -> Login: admin/password -> Setup -> Create/Reset DB if needed."
}

require_root
mkdir -p "$(dirname "$LOG")"; touch "$LOG"
log "Starting DVWA Auto Installer v$INSTALLER_VER"

install_packages
fix_apache_php
setup_database
clone_dvwa
fix_permissions
update_config
final_steps
exit 0
