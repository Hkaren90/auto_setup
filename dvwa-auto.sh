#!/bin/bash
set -e

INSTALLER_VERSION="1.2"
DVWA_DIR="/var/www/html/dvwa"
DB_USER="dvwa"
DB_PASS="password"
DB_NAME="dvwa"

log() { echo "[+] $1"; }

log "Installer version $INSTALLER_VERSION starting..."

# Update & install packages
log "Updating apt cache and installing required packages..."
apt update -y
apt install -y apache2 mariadb-server php php-mysql php-gd php-xml php-curl php-zip libapache2-mod-php git unzip

# Enable & start services
systemctl enable apache2 || true
systemctl enable mariadb || true
systemctl start apache2 || true
systemctl start mariadb || true

# Remove old DVWA folder if exists
if [ -d "$DVWA_DIR" ]; then
    log "Removing old DVWA directory..."
    rm -rf "$DVWA_DIR"
fi

# Drop old DB and user if exists
log "Dropping old DVWA database and user if they exist..."
mysql -u root <<EOF
DROP DATABASE IF EXISTS $DB_NAME;
DROP USER IF EXISTS '$DB_USER'@'localhost';
EOF

# Create new DB and user
log "Creating new DVWA database and user..."
mysql -u root <<EOF
CREATE DATABASE $DB_NAME;
CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

# Clone DVWA
log "Cloning DVWA repository..."
git clone https://github.com/digininja/DVWA.git "$DVWA_DIR"

# Permissions
log "Setting permissions..."
chown -R www-data:www-data "$DVWA_DIR"
find "$DVWA_DIR" -type d -exec chmod 755 {} \;
find "$DVWA_DIR" -type f -exec chmod 644 {} \;
chmod -R 770 "$DVWA_DIR/hackable/uploads"

# Configure DVWA
log "Preparing DVWA config..."
cp "$DVWA_DIR/config/config.inc.php" "$DVWA_DIR/config/config.inc.php.bak.$(date +%s)"
sed -i "s/'db_user' ] = .*/'db_user' ] = '$DB_USER';/g" "$DVWA_DIR/config/config.inc.php"
sed -i "s/'db_password' ] = .*/'db_password' ] = '$DB_PASS';/g" "$DVWA_DIR/config/config.inc.php"
sed -i "s/'db_database' ] = .*/'db_database' ] = '$DB_NAME';/g" "$DVWA_DIR/config/config.inc.php"

# Restart Apache
log "Restarting Apache..."
systemctl restart apache2 || true

log "DVWA installation complete!"
echo "Open in browser: http://127.0.0.1/dvwa"
echo "Login: admin / password"
echo "Then click: 'Create / Reset Database'"
