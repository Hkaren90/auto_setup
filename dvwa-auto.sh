#!/bin/bash
#
# --------------------------------------------------------------------------------------
# DVWA Universal Auto Installer v2.0
# --------------------------------------------------------------------------------------
# This script automatically installs or completely resets and reinstalls DVWA.
# It handles existing installations, database users, permissions, and Git errors.
# Compatibility: Designed for Debian/Ubuntu/Kali-based systems.
#
# USAGE: sudo bash dvwa_setup.sh
# --------------------------------------------------------------------------------------

set -e

# --- CONFIGURATION ---
INSTALLER_VERSION="2.0"
DVWA_DIR="/var/www/html/dvwa"
DB_USER="dvwa"
DB_PASS="password" # Change this password for production use (though not recommended for DVWA)
DB_NAME="dvwa"
# Note: Using generic PHP package names (e.g., php-mysql) as apt usually links to the active version.
REQUIRED_PACKAGES="apache2 mariadb-server php php-mysql php-gd php-xml php-curl php-zip php-mbstring libapache2-mod-php git unzip"

# --- UTILITY FUNCTIONS ---

log() { echo -e "\n[+] \033[1;32m$1\033[0m"; } # Green for success/info
fail_exit() {
    echo -e "\n[!] \033[1;31mFATAL ERROR: $1\033[0m"
    exit 1
}

# Function to run MariaDB commands securely as root
run_mysql() {
    # Attempt to connect to MariaDB as root using sudo.
    # This is the most reliable way on Linux VMs/Kali where root password is often unset/known to OS.
    sudo mysql -u root -e "$1"
    if [ $? -ne 0 ]; then
        fail_exit "MariaDB command failed. Check if 'mariadb-server' is installed and running."
    fi
}

# --- MAIN INSTALLATION STEPS ---

log "DVWA Auto Installer version $INSTALLER_VERSION starting..."
echo "Configuration: DB User=$DB_USER, DB Name=$DB_NAME, DVWA Path=$DVWA_DIR"

# 1. System Update & Packages
# --------------------------------------------------------------------------------------
log "Updating apt cache and installing required packages..."
apt update -y
apt install -y $REQUIRED_PACKAGES || fail_exit "Failed to install required system packages."

# 2. Enable & Start Services
# --------------------------------------------------------------------------------------
log "Ensuring Apache and MariaDB services are running..."
systemctl enable apache2 || true
systemctl enable mariadb || true
systemctl start apache2 || true
systemctl start mariadb || true

# 3. DVWA Directory Cleanup & Reset (Handles #6)
# --------------------------------------------------------------------------------------
log "Performing clean slate setup: Cleaning up old DVWA directory..."
if [ -d "$DVWA_DIR" ]; then
    log "Existing DVWA directory found at $DVWA_DIR. Deleting to ensure fresh clone..."
    rm -rf "$DVWA_DIR" || fail_exit "Failed to delete old DVWA directory."
fi

# 4. Git Clone (Handles #4)
# --------------------------------------------------------------------------------------
log "Cloning fresh DVWA repository..."
git clone https://github.com/digininja/DVWA.git "$DVWA_DIR" || fail_exit "Failed to clone DVWA repository."

# Fix Git dubious ownership issue (Handles #4)
# This prevents errors if /var/www/html is mounted from an external filesystem or owned by root.
log "Fixing Git 'dubious ownership' for the repository..."
git config --global --add safe.directory "$DVWA_DIR" 2>/dev/null || true

# 5. MariaDB Cleanup and Setup (Handles #1, #2)
# --------------------------------------------------------------------------------------
log "MariaDB Setup: Dropping old database and user, then creating fresh ones..."

# a. Drop Database (if exists)
log "  -> Dropping old database '$DB_NAME'..."
run_mysql "DROP DATABASE IF EXISTS $DB_NAME;"

# b. Drop User (if exists)
log "  -> Dropping old user '$DB_USER'@'localhost'..."
run_mysql "DROP USER IF EXISTS '$DB_USER'@'localhost';"

# c. Create Database, User, and Grant Privileges
log "  -> Creating fresh database, user, and granting privileges..."
MYSQL_COMMANDS=$(cat <<EOF
CREATE DATABASE $DB_NAME;
CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF
)
run_mysql "$MYSQL_COMMANDS"

# 6. Configure DVWA (Handles #5)
# --------------------------------------------------------------------------------------
log "Configuring DVWA (config.inc.php)..."

# Create config file from example
CONFIG_PATH="$DVWA_DIR/config/config.inc.php"
if [ ! -f "$CONFIG_PATH" ]; then
    cp "$DVWA_DIR/config/config.inc.php.dist" "$CONFIG_PATH"
fi

# Update database credentials in the config file
sed -i "s/\$DVWA\['db_user'\] = '.*';/\$DVWA\['db_user'\] = '$DB_USER';/g" "$CONFIG_PATH"
sed -i "s/\$DVWA\['db_password'\] = '.*';/\$DVWA\['db_password'\] = '$DB_PASS';/g" "$CONFIG_PATH"
sed -i "s/\$DVWA\['db_database'\] = '.*';/\$DVWA\['db_database'\] = '$DB_NAME';/g" "$CONFIG_PATH"
sed -i "s/\$DVWA\['db_server'\] = '.*';/\$DVWA\['db_server'\] = 'localhost';/g" "$CONFIG_PATH"

# Set allow_url_include to 'On' for certain RCE challenges (optional but helpful for completeness)
sed -i "s/\$DVWA\['recaptcha_public_key'\] = .*/\$DVWA\['recaptcha_public_key'\] = '';\n\$DVWA\['recaptcha_private_key'\] = '';/g" "$CONFIG_PATH"


# 7. Permissions (Handles #5, #3)
# --------------------------------------------------------------------------------------
log "Setting proper permissions (www-data ownership)..."
# Set www-data ownership (most common and secure for Apache)
chown -R www-data:www-data "$DVWA_DIR" || fail_exit "Failed to set www-data ownership."

# Set standard permissions
find "$DVWA_DIR" -type d -exec chmod 755 {} \;
find "$DVWA_DIR" -type f -exec chmod 644 {} \;

# Set permissive permissions for the uploads and PHPIDS folder (required for DVWA functions)
chmod -R 777 "$DVWA_DIR/hackable/uploads"
chmod -R 777 "$DVWA_DIR/external/phpids/0.6/lib/IDS/tmp"


# 8. Restart Apache
# --------------------------------------------------------------------------------------
log "Restarting Apache to apply configuration and PHP module changes..."
systemctl restart apache2 || true

# 9. Finish
# --------------------------------------------------------------------------------------
log "DVWA installation/reset complete! (Version $INSTALLER_VERSION)"
echo "========================================================================================="
echo "ACCESS DVWA:"
echo "Open in browser: \033[1;34mhttp://127.0.0.1/dvwa\033[0m"
echo "Default Login: admin / password"
echo ""
echo "!!! IMPORTANT !!!"
echo "You must click the '\033[1;33mCreate / Reset Database\033[0m' button inside DVWA to finalize the setup."
echo "========================================================================================="
