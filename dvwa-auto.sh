#!/bin/bash
set -e

log() {
    echo "[+] $1"
}

log "Updating system (safe, idempotent)..."
apt update -y
apt install -y apache2 mariadb-server php php-mysql php-gd php-xml php-curl php-zip libapache2-mod-php git unzip

systemctl enable apache2 || true
systemctl enable mariadb || true
systemctl start apache2 || true
systemctl start mariadb || true

log "Setting up MariaDB database and user..."
mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS dvwa;
CREATE USER IF NOT EXISTS 'dvwa'@'localhost' IDENTIFIED BY 'password';
GRANT ALL PRIVILEGES ON dvwa.* TO 'dvwa'@'localhost';
FLUSH PRIVILEGES;
EOF

DVWA_DIR="/var/www/html/dvwa"

log "Installing or updating DVWA..."

if [ -d "$DVWA_DIR/.git" ]; then
    log "DVWA exists — resetting and pulling latest version."
    git -C "$DVWA_DIR" reset --hard
    git -C "$DVWA_DIR" pull || true
else
    log "Fresh install — cloning DVWA."
    rm -rf "$DVWA_DIR"
    git clone https://github.com/digininja/DVWA.git "$DVWA_DIR"
fi

log "Setting permissions..."
chown -R www-data:www-data "$DVWA_DIR"
find "$DVWA_DIR" -type d -exec chmod 755 {} \;
find "$DVWA_DIR" -type f -exec chmod 644 {} \;
chmod -R 770 "$DVWA_DIR/hackable/uploads"

log "Preparing DVWA config file..."
cp "$DVWA_DIR/config/config.inc.php" "$DVWA_DIR/config/config.inc.php.bak.$(date +%s)"

sed -i "s/'db_user' ] = .*/'db_user' ] = 'dvwa';/g" "$DVWA_DIR/config/config.inc.php"
sed -i "s/'db_password' ] = .*/'db_password' ] = 'password';/g" "$DVWA_DIR/config/config.inc.php"
sed -i "s/'db_database' ] = .*/'db_database' ] = 'dvwa';/g" "$DVWA_DIR/config/config.inc.php"

log "Restarting Apache..."
systemctl restart apache2 || true

log "DONE!"
echo "Visit: http://127.0.0.1/dvwa"
echo "Login: admin / password"
echo "Then click: 'Create / Reset Database'"
