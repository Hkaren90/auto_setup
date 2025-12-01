#!/bin/bash
#
# --------------------------------------------------------------------------------------
# DVWA Universal Auto Installer v3.3 (Authentication Fix: 127.0.0.1 Grant)
# --------------------------------------------------------------------------------------
# This script performs a "Scorched Earth" installation:
# 1. DELETE existing DVWA folder completely.
# 2. DROP existing database and user.
# 3. Install fresh with ROBUST authentication fixes, granting access to both 
#    'localhost' and '127.0.0.1' for universal PHP compatibility.
# 4. VERIFY the database connection before finishing.
#
# USAGE: sudo bash dvwa_setup.sh
# --------------------------------------------------------------------------------------

set -e

# --- CONFIGURATION ---
INSTALLER_VERSION="3.3"
DVWA_DIR="/var/www/html/dvwa"
DB_USER="dvwa"
DB_PASS="password" # Change this password for production use
DB_NAME="dvwa"
DB_HOST="127.0.0.1" # Explicitly use 127.0.0.1 for consistent TCP connections
# Include essential PHP extensions for compatibility
REQUIRED_PACKAGES="apache2 mariadb-server php php-mysql php-gd php-xml php-curl php-zip php-mbstring libapache2-mod-php git unzip"

# --- UTILITY FUNCTIONS ---

log() { echo -e "\n[+] \033[1;32m$1\033[0m"; } # Green for success/info
warn() { echo -e "\n[!] \033[1;33m$1\033[0m"; } # Yellow for warning
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

# b. Drop Users (for both localhost and 127.0.0.1)
run_mysql "DROP USER IF EXISTS '$DB_USER'@'localhost';"
run_mysql "DROP USER IF EXISTS '$DB_USER'@'$DB_HOST';"

# c. Create Database, User, and Grant Privileges
log "  -> Creating fresh database and user (granting access from 127.0.0.1 and localhost)..."

# 1. Create database
run_mysql "CREATE DATABASE $DB_NAME;"

# 2. Create user with standard syntax for both hosts.
run_mysql "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';"
run_mysql "CREATE USER '$DB_USER'@'$DB_HOST' IDENTIFIED BY '$DB_PASS';"

# 3. Grant privileges to both users
run_mysql "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';"
run_mysql "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'$DB_HOST';"

# 4. PLUGIN FIX (Critical for "Access Denied" errors)
#    We only need to fix one user, as the grants are shared. We use the 127.0.0.1 grant.
log "  -> Fixing Authentication Plugin for TCP connection (Attempting methods for compatibility)..."

if echo "ALTER USER '$DB_USER'@'$DB_HOST' IDENTIFIED WITH mysql_native_password BY '$DB_PASS';" | sudo mysql -u root 2>/dev/null; then
    log "     (Method 1 [ALTER USER] Success: Native password plugin set for $DB_HOST.)"
else
    log "     (Method 1 failed. Trying Method 2 [SET PASSWORD]...)"
    # Fallback for older MariaDB versions or specific configurations
    if echo "SET PASSWORD FOR '$DB_USER'@'$DB_HOST' = PASSWORD('$DB_PASS');" | sudo mysql -u root 2>/dev/null; then
        log "     (Method 2 [SET PASSWORD] Success: Password set for $DB_HOST.)"
    else
         warn "     (Both plugin fix methods failed. Connection might still fail.)"
    fi
fi

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
# FIX: Use 127.0.0.1 explicitly
sed -i "s/\$DVWA\['db_server'\] = '.*';/\$DVWA\['db_server'\] = '$DB_HOST';/g" "$CONFIG_PATH"

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

# 8. VERIFICATION (New Step)
# --------------------------------------------------------------------------------------
log "Verifying Database Connection..."
# Test connection explicitly using 127.0.0.1
TEST_PHP=$(cat <<EOF
<?php
\$conn = @new mysqli('$DB_HOST', '$DB_USER', '$DB_PASS', '$DB_NAME');
if (\$conn->connect_error) {
    fwrite(STDERR, "DB Connection Failed: " . \$conn->connect_error);
    exit(1);
}
echo "DB Connection Successful!";
?>
EOF
)

if echo "$TEST_PHP" | php; then
    log "Database check PASSED. DVWA is ready."
else
    fail_exit "Database connection check FAILED. See error above."
fi

# 9. Finish
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
