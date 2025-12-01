#!/bin/bash
#
# --------------------------------------------------------------------------------------
# DVWA Universal Auto Installer v3.1 (Chaos Mode: Fresh Install Only)
# --------------------------------------------------------------------------------------
# This script performs a "Scorched Earth" installation:
# 1. DELETE existing DVWA folder completely.
# 2. DROP existing database and user.
# 3. Install everything fresh from scratch.
#
# USAGE: sudo bash dvwa_setup.sh
# --------------------------------------------------------------------------------------

set -e

# --- CONFIGURATION ---
INSTALLER_VERSION="3.1"
DVWA_DIR="/var/www/html/dvwa"
DB_USER="dvwa"
DB_PASS="password" # Change this password for production use
DB_NAME="dvwa"
# Include essential PHP extensions for compatibility
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
    echo "$1" | sudo mysql -u root
    if [ $? -ne 0 ]; then
        fail_exit "MariaDB command failed with command: $1"
    fi
}

# Function to find the active PHP configuration file (php.ini)
find_php_ini() {
    # Finds the php.ini path used by the CLI (matches web environment usually)
    php -i 2>/dev/null | grep -E "^Configuration File (Path|Used)" | awk '{print $NF}' | head -n 1
}

# --- MAIN INSTALLATION STEPS ---

log "DVWA Auto Installer version $INSTALLER_VERSION starting..."
echo "Mode: FRESH INSTALL (Deleting previous data)"

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

# 3. DVWA Directory Management (The "Chaos" Clean Start)
# --------------------------------------------------------------------------------------
log "Cleaning up old DVWA installation..."

if [ -d "$DVWA_DIR" ]; then
    log "  -> Found existing directory. DELETING it completely..."
    rm -rf "$DVWA_DIR" || fail_exit "Failed to delete old directory."
else
    log "  -> No existing directory found. Proceeding."
fi

log "  -> Cloning fresh DVWA repository..."
git clone https://github.com/digininja/DVWA.git "$DVWA_DIR" || fail_exit "Failed to clone DVWA repository."

# Fix Git dubious ownership issue immediately after clone
git config --global --add safe.directory "$DVWA_DIR" 2>/dev/null || true

# 4. MariaDB Cleanup and Setup
# --------------------------------------------------------------------------------------
log "MariaDB Setup: Dropping old database/user and creating fresh..."

# a. Drop Database (if exists)
run_mysql "DROP DATABASE IF EXISTS $DB_NAME;"

# b. Drop User (if exists)
run_mysql "DROP USER IF EXISTS '$DB_USER'@'localhost';"

# c. Create Database, User, and Grant Privileges
# We use standard commands that work on ALL versions.
log "  -> Creating fresh database and user..."

# 1. Create database
run_mysql "CREATE DATABASE $DB_NAME;"

# 2. Create user with standard syntax. 
run_mysql "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';"

# 3. Grant privileges
run_mysql "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';"

# 4. Optional: Best-effort plugin fix. 
#    We try to force 'mysql_native_password' just in case, but we DO NOT exit if this fails 
#    (preventing crashes on DB versions that don't support/need this syntax).
log "  -> Ensuring PHP compatibility (Best effort)..."
echo "ALTER USER '$DB_USER'@'localhost' IDENTIFIED WITH mysql_native_password BY '$DB_PASS';" | sudo mysql -u root >/dev/null 2>&1 || true

# 5. Flush privileges
run_mysql "FLUSH PRIVILEGES;"


# 5. Configure DVWA & PHP Safety Settings
# --------------------------------------------------------------------------------------
log "Configuring DVWA and enabling required PHP vulnerability settings..."

# Find the active PHP configuration file (php.ini)
PHP_INI_PATH=$(find_php_ini)
if [ -z "$PHP_INI_PATH" ] || [ ! -f "$PHP_INI_PATH" ]; then
    # Fallback path if auto-detection fails
    PHP_INI_PATH=$(find /etc/php -name php.ini -path "*/apache2/*" | head -n 1)
fi

if [ -f "$PHP_INI_PATH" ]; then
    log "  -> Modifying active PHP configuration file: $PHP_INI_PATH"
    # Essential for File Inclusion RFI challenges
    sed -i 's/allow_url_fopen = Off/allow_url_fopen = On/g' "$PHP_INI_PATH"
    sed -i 's/allow_url_include = Off/allow_url_include = On/g' "$PHP_INI_PATH"
    # Essential for Command Execution challenges
    sed -i 's/safe_mode = On/safe_mode = Off/g' "$PHP_INI_PATH" 2>/dev/null || true
fi

# Create DVWA config file from example
CONFIG_PATH="$DVWA_DIR/config/config.inc.php"
if [ ! -f "$CONFIG_PATH" ]; then
    cp "$DVWA_DIR/config/config.inc.php.dist" "$CONFIG_PATH"
fi

# Update database credentials in the DVWA config file
sed -i "s/\$DVWA\['db_user'\] = '.*';/\$DVWA\['db_user'\] = '$DB_USER';/g" "$CONFIG_PATH"
sed -i "s/\$DVWA\['db_password'\] = '.*';/\$DVWA\['db_password'\] = '$DB_PASS';/g" "$CONFIG_PATH"
sed -i "s/\$DVWA\['db_database'\] = '.*';/\$DVWA\['db_database'\] = '$DB_NAME';/g" "$CONFIG_PATH"
sed -i "s/\$DVWA\['db_server'\] = '.*';/\$DVWA\['db_server'\] = 'localhost';/g" "$CONFIG_PATH"

# Disable reCAPTCHA keys
sed -i "s/\$DVWA\['recaptcha_public_key'\] = .*/\$DVWA\['recaptcha_public_key'\] = '';\n\$DVWA\['recaptcha_private_key'\] = '';/g" "$CONFIG_PATH"


# 6. Permissions
# --------------------------------------------------------------------------------------
log "Setting proper permissions (www-data ownership)..."
chown -R www-data:www-data "$DVWA_DIR" || fail_exit "Failed to set www-data ownership."

# Set standard permissions
find "$DVWA_DIR" -type d -exec chmod 755 {} \;
find "$DVWA_DIR" -type f -exec chmod 644 {} \;

# --- Create the PHPIDS temp directory before setting permissions ---
PHPIDS_TMP_DIR="$DVWA_DIR/external/phpids/0.6/lib/IDS/tmp"
if [ ! -d "$PHPIDS_TMP_DIR" ]; then
    log "  -> Creating missing PHPIDS temporary directory: $PHPIDS_TMP_DIR"
    mkdir -p "$PHPIDS_TMP_DIR" || fail_exit "Failed to create PHPIDS tmp directory."
fi

# Set permissive permissions for the uploads and PHPIDS folder
chmod -R 777 "$DVWA_DIR/hackable/uploads"
chmod -R 777 "$PHPIDS_TMP_DIR"


# 7. Restart Apache
# --------------------------------------------------------------------------------------
log "Restarting Apache..."
systemctl reload apache2 || true

# 8. Finish
# --------------------------------------------------------------------------------------
log "DVWA installation/reset complete! (Fresh Install)"
echo "========================================================================================="
echo "ACCESS DVWA:"
echo "Open in browser: \033[1;34mhttp://127.0.0.1/dvwa\033[0m"
echo "Default Login: admin / password"
echo ""
echo "!!! IMPORTANT !!!"
echo "You must click the '\033[1;33mCreate / Reset Database\033[0m' button inside DVWA to finalize the setup."
echo "========================================================================================="
