#!/bin/bash
set -e

# --------------------------
# DVWA Auto Installer v1.1
# --------------------------

INSTALLER_VERSION="1.1"
DVWA_DIR="/var/www/html/dvwa"
DB_USER="dvwa"
DB_PASS="password"
DB_NAME="dvwa"

log() { echo "[+] $1"; }

log "Installer version $INSTALLER_VERSION starting..."

# ---------- System Update & Packages ----------
log "Updating apt cache and installing required packages..."
apt update -y
apt install -y apache2 mariadb-server php php-mysql php-gd php-xml php-curl php-zip libapache2-mod-php git unzip

# ---------- Enable & Start Services ----------
systemctl enable apache2 || true
systemctl enable mariadb || true
systemctl start apache2 || true
systemctl start mariadb || true

# ---------- Setup MariaDB Database ----------
log "Creating or updating MariaDB database and user (idempotent)..."
mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS $DB_NAME;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

# ---------- Install or Update DVWA ----------
if [ -d "$DVWA_DIR/.git" ]; then
    log "DVWA exists — resetting repo and pulling latest changes..."
    git config --global --add safe.directory "$DVWA_DIR" 2>/dev/null || true
    git -C "$DVWA_DIR" reset --hard
    git -C "$DVWA_DIR" pull || true
else
    log "DVWA not found — cloning fresh..."
    rm -rf "$DVWA_DIR"
    git clone https://github.com/digininja/DVWA.git "$DVWA_DIR"
fi

# ---------- Permissions ----------
log "Setting proper permissions..."
chown -R www-data:www-data "$DVWA_DIR"
find "$DVWA_DIR" -type d -exec chmod 755 {} \;
find "$DVWA_DIR" -type f -exec chmod 644 {} \;
chmod -R 770 "$DVWA_DIR/hackable/uploads"

# ---------- Configure DVWA ----------
log "Preparing DVWA config..."
cp "$DVWA_DIR/config/config.inc.php" "$DVWA_DIR/config/config.inc.php.bak.$(date +%s)"
sed -i "s/'db_user' ] = .*/'db_user' ] = '$DB_USER';/g" "$DVWA_DIR/config/config.inc.php"
sed -i "s/'db_password' ] = .*/'db_password' ] = '$DB_PASS';/g" "$DVWA_DIR/config/config.inc.php"
sed -i "s/'db_database' ] = .*/'db_database' ] = '$DB_NAME';/g" "$DVWA_DIR/config/config.inc.php"

# ---------- Restart Apache ----------
log "Restarting Apache..."
systemctl restart apache2 || true

# ---------- Finish ----------
log "DVWA installation/update complete!"
echo "Open in browser: http://127.0.0.1/dvwa"
echo "Login: admin / password"
echo "Then click: 'Create / Reset Database'"

