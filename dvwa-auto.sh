#!/bin/bash
set -e

INSTALLER_VERSION="2.0"
DVWA_DIR="/var/www/html/dvwa"
DB_USER="dvwa"
DB_PASS="password"
DB_NAME="dvwa"

echo "[+] Starting installer $INSTALLER_VERSION"

apt update -y
apt install -y apache2 mariadb-server php php-mysql php-gd php-xml php-curl php-zip libapache2-mod-php git unzip

systemctl enable apache2 || true
systemctl enable mariadb || true
systemctl start apache2 || true
systemctl start mariadb || true

if [ -d "$DVWA_DIR" ]; then
    echo "[+] Removing old DVWA directory..."
    rm -rf "$DVWA_DIR"
fi

echo "[+] Dropping old database and user..."
mysql -u root <<EOF
DROP DATABASE IF EXISTS $DB_NAME;
DROP USER IF EXISTS '$DB_USER'@'localhost';
EOF

echo "[+] Creating fresh database and user..."
mysql -u root <<EOF
CREATE DATABASE $DB_NAME;
CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

echo "[+] Cloning DVWA..."
git clone https://github.com/digininja/DVWA.git "$DVWA_DIR"

echo "[+] Setting correct permissions..."
chown -R www-data:www-data "$DVWA_DIR"
find "$DVWA_DIR" -type d -exec chmod 755 {} \;
find "$DVWA_DIR" -type f -exec chmod 644 {} \;
chmod -R 770 "$DVWA_DIR/hackable/uploads"

echo "[+] Creating DVWA config..."
cp "$DVWA_DIR/config/config.inc.php.dist" "$DVWA_DIR/config/config.inc.php"

sed -i "s/'db_user'.*;/\t'db_user' ] = '$DB_USER';/g" "$DVWA_DIR/config/config.inc.php"
sed -i "s/'db_password'.*;/\t'db_password' ] = '$DB_PASS';/g" "$DVWA_DIR/config/config.inc.php"
sed -i "s/'db_database'.*;/\t'db_database' ] = '$DB_NAME';/g" "$DVWA_DIR/config/config.inc.php"

echo "[+] Restarting Apache..."
systemctl restart apache2

echo "[+] DVWA installation complete!"
echo "Open: http://127.0.0.1/dvwa"
echo "Login: admin / password"
echo "Click: Create / Reset Database"
