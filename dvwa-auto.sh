#!/bin/bash
set -e

# -----------------------------------------
# DVWA Full Reset + Auto Installer v2.0
# -----------------------------------------

INSTALLER_VERSION="2.0"
DVWA_DIR="/var/www/html/dvwa"
DB_USER="dvwa"
DB_PASS="password"
DB_NAME="dvwa"

log(){ echo "[+] $1"; }

log "Starting DVWA Full Reset & Fresh Install (v$INSTALLER_VERSION)..."

# ---------------- System Update ----------------
#log "Updating system & installing required packages..."
#apt update -y
#apt install -y apache2 mariadb-server php php-mysql php-gd php-xml php-curl php-zip libapache2-mod-php git unzip

# ---------------- Enable Services --------------
systemctl enable apache2 || true
systemctl enable mariadb || true
systemctl start apache2 || true
systemctl start mariadb || true

# --------------- CLEAN OLD DVWA ----------------
log "Removing any previous DVWA installation..."
rm -rf "$DVWA_DIR"

log "Clearing old DVWA database & user..."
mysql -u root <<EOF
DROP DATABASE IF EXISTS $DB_NAME;
DROP USER IF EXISTS '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

# --------------- RECREATE DB -------------------
log "Creating new database and user..."
mysql -u root <<EOF
CREATE DATABASE $DB_NAME;
CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

# ---------------- INSTALL DVWA -----------------
log "Cloning fresh DVWA from GitHub..."
git clone https://github.com/digininja/DVWA.git "$DVWA_DIR"

# ---------------- PERMISSIONS ------------------
log "Setting correct permissions..."
chown -R www-data:www-data "$DVWA_DIR"
find "$DVWA_DIR" -type d -exec chmod 755 {} \;
find "$DVWA_DIR" -type f -exec chmod 644 {} \;
chmod -R 770 "$DVWA_DIR/hackable/uploads"

# ---------------- CONFIGURE DVWA ---------------
log "Configuring DVWA..."
cp "$DVWA_DIR/config/config.inc.php.dist" "$DVWA_DIR/config/config.inc.php"

sed -i "s/'db_user'.*/'db_user'] = '$DB_USER';/g" "$DVWA_DIR/config/config.inc.php"
sed -i "s/'db_password'.*/'db_password'] = '$DB_PASS';/g" "$DVWA_DIR/config/config.inc.php"
sed -i "s/'db_database'.*/'db_database'] = '$DB_NAME';/g" "$DVWA_DIR/config/config.inc.php"

# ---------------- RESTART APACHE ---------------
log "Restarting Apache..."
systemctl restart apache2 || true

# ---------------- FINISH -----------------------
log "DVWA completely reset and reinstalled!"
echo "URL: http://127.0.0.1/dvwa"
echo "Login: admin / password"
echo "Then click: 'Create / Reset Database'"
