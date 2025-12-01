#!/bin/bash
#
# --------------------------------------------------------------------------------------
# DVWA Universal Auto Installer v2.8 (Final Hardened Version)
# --------------------------------------------------------------------------------------
# This script automatically installs or completely resets and reinstalls DVWA.
# It ensures maximum compatibility across Linux distros, modern MariaDB versions,
# and all necessary PHP vulnerability settings are enabled.
#
# USAGE: sudo bash dvwa_setup.sh
# --------------------------------------------------------------------------------------

set -e

# --- CONFIGURATION ---
INSTALLER_VERSION="2.8"
DVWA_DIR="/var/www/html/dvwa"
DB_USER="dvwa"
DB_PASS="password" # Change this password for production use (though not recommended for DVWA)
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
    # We pipe the commands to avoid complex quoting in the shell.
    echo "$1" | sudo mysql -u root
    if [ $? -ne 0 ]; then
        fail_exit "MariaDB command failed. Check if 'mariadb-server' is installed and running."
    fi
}

# Function to find the active PHP configuration file (php.ini)
find_php_ini() {
    # Finds the php.ini path used by the CLI (which usually matches the web environment for modules)
    php -i 2>/dev/null | grep -E "^Configuration File (Path|Used)" | awk '{print $NF}' | head -n 1
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

# 3. DVWA Directory Management (Update or Clone)
# --------------------------------------------------------------------------------------
log "Handling DVWA directory: Checking for existing installation..."

if [ -d "$DVWA_DIR/.git" ]; then
    log "Existing DVWA repository found. Resetting and pulling latest changes to update..."
    
    # Fix Git dubious ownership issue
    git config --global --add safe.directory "$DVWA_DIR" 2>/dev/null || true

    # Use reset/pull to ensure a clean, up-to-date state
    git -C "$DVWA_DIR" reset --hard || log "Warning: Git hard reset failed, proceeding with pull..."
    git -C "$DVWA_DIR" pull --rebase || fail_exit "Failed to update DVWA repository via Git pull."

elif [ -d "$DVWA_DIR" ]; then
    # Directory exists but is not a Git repo (incomplete clone, manual install, etc.)
    log "Existing directory found at $DVWA_DIR, but it is NOT a valid Git repo. Deleting and cloning fresh..."
    rm -rf "$DVWA_DIR" || fail_exit "Failed to delete old non-Git DVWA directory."
    git clone https://github.com/digininja/DVWA.git "$DVWA_DIR" || fail_exit "Failed to clone DVWA repository."
    
else
    # Directory does not exist, perform fresh clone
    log "DVWA directory not found. Cloning fresh DVWA repository..."
    git clone https://github.com/digininja/DVWA.git "$DVWA_DIR" || fail_exit "Failed to clone DVWA repository."
fi

# 4. MariaDB Cleanup and Setup (The Final Fix for Syntax and Compatibility)
# --------------------------------------------------------------------------------------
log "MariaDB Setup: Dropping old database and user, then creating fresh ones with universal syntax..."

# a. Drop Database (if exists)
log "  -> Dropping old database '$DB_NAME'..."
run_mysql "DROP DATABASE IF EXISTS $DB_NAME;"

# b. Drop User (if exists)
log "  -> Dropping old user '$DB_USER'@'localhost'..."
run_mysql "DROP USER IF EXISTS '$DB_USER'@'localhost';"

# c. Create Database, User, and Grant Privileges
log "  -> Creating fresh database, user, and applying 'mysql_native_password' for PHP compatibility..."
MYSQL_COMMANDS=$(cat <<EOF
CREATE DATABASE $DB_NAME;
-- 1. Create user with the most standard, unambiguous syntax.
CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
-- 2. FORCE the use of 'mysql_native_password' plugin via direct table update.
--    This is the non-negotiable fix for PHP connection errors across modern versions.
UPDATE mysql.user SET plugin='mysql_native_password' WHERE User='$DB_USER' AND Host='localhost';
-- 3. Grant privileges separately, avoiding syntax conflicts with IDENTIFIED BY.
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF
)
run_mysql "$MYSQL_COMMANDS"

# 5. Configure DVWA & PHP Safety Settings
# --------------------------------------------------------------------------------------
log "Configuring DVWA and enabling required PHP vulnerability settings..."

# Find the active PHP configuration file (php.ini)
PHP_INI_PATH=$(find_php_ini)
if [ -z "$PHP_INI_PATH" ] || [ ! -f "$PHP_INI_PATH" ]; then
    # Fallback path if auto-detection fails (common path for web PHP config)
    PHP_INI_PATH=$(find /etc/php -name php.ini -path "*/apache2/*" | head -n 1)
    if [ -z "$PHP_INI_PATH" ]; then
        log "Warning: Could not reliably find active php.ini file. Proceeding with DVWA config only."
    fi
fi

if [ -f "$PHP_INI_PATH" ]; then
    log "  -> Modifying active PHP configuration file: $PHP_INI_PATH"
    # Essential for File Inclusion RFI challenges
    sed -i 's/allow_url_fopen = Off/allow_url_fopen = On/g' "$PHP_INI_PATH"
    sed -i 's/allow_url_include = Off/allow_url_include = On/g' "$PHP_INI_PATH"
    # Essential for Command Execution challenges
    sed -i 's/safe_mode = On/safe_mode = Off/g' "$PHP_INI_PATH" 2>/dev/null || true # safe_mode is deprecated but good to fix if present
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
# Set www-data ownership (most common and secure for Apache)
chown -R www-data:www-data "$DVWA_DIR" || fail_exit "Failed to set www-data ownership."

# Set standard permissions
find "$DVWA_DIR" -type d -exec chmod 755 {} \;
find "$DVWA_DIR" -type f -exec chmod 644 {} \;

# --- FIX: Create the PHPIDS temp directory before setting permissions ---
PHPIDS_TMP_DIR="$DVWA_DIR/external/phpids/0.6/lib/IDS/tmp"
if [ ! -d "$PHPIDS_TMP_DIR" ]; then
    log "  -> Creating missing PHPIDS temporary directory: $PHPIDS_TMP_DIR"
    mkdir -p "$PHPIDS_TMP_DIR" || fail_exit "Failed to create PHPIDS tmp directory."
fi
# --- END FIX ---

# Set permissive permissions for the uploads and PHPIDS folder (required for DVWA functions)
chmod -R 777 "$DVWA_DIR/hackable/uploads"
chmod -R 777 "$PHPIDS_TMP_DIR"


# 7. Restart Apache
# --------------------------------------------------------------------------------------
log "Restarting Apache to apply configuration and PHP module changes..."
# Graceful restart is generally safer than a full stop/start
systemctl reload apache2 || true

# 8. Finish
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
