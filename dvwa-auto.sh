#!/bin/bash

################################################################################
# DVWA Universal Auto Installer v2.0 (Production Ready)
# ────────────────────────────────────────────────────────────────────────────
# Compatible: Debian/Ubuntu/Kali Linux & derivatives
# Features: Idempotent • Error-Proof • Cross-Machine Compatible
#
# Usage: curl -fsSL https://github.com/YOUR_USERNAME/dvwa-installer/raw/main/install.sh | sudo bash
# Or:    wget -qO- https://github.com/YOUR_USERNAME/dvwa-installer/raw/main/install.sh | sudo bash
################################################################################

set -euo pipefail

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# COLOR & LOGGING
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

INSTALLER_VERSION="2.0"
DVWA_DIR="/var/www/html/dvwa"
DB_USER="dvwa"
DB_PASS="password"
DB_NAME="dvwa"
LOG_FILE="/tmp/dvwa_installer_$(date +%s).log"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# UTILITY FUNCTIONS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log_info() {
    echo -e "${BLUE}[ℹ]${NC} $1" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1" | tee -a "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}[⚠]${NC} $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1" | tee -a "$LOG_FILE"
}

log_section() {
    echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}[*] $1${NC}" | tee -a "$LOG_FILE"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

root_check() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use: sudo)"
        exit 1
    fi
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# SYSTEM DETECTION
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

detect_system() {
    log_section "System Detection"
    
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_NAME="$ID"
        OS_VERSION="$VERSION_ID"
        log_info "OS: $PRETTY_NAME"
    else
        log_error "Could not detect OS"
        exit 1
    fi

    PHP_VERSION=$(php -r "echo implode('.', array_slice(explode('.', PHP_VERSION), 0, 2));" 2>/dev/null || echo "not_installed")
    log_info "PHP: $PHP_VERSION"

    APACHE_VERSION=$(apachectl -v 2>/dev/null | grep "Apache/" | awk '{print $3}' | cut -d'/' -f2 || echo "not_installed")
    log_info "Apache: $APACHE_VERSION"

    MYSQL_VERSION=$(mysql --version 2>/dev/null || echo "not_installed")
    log_info "MySQL/MariaDB: $MYSQL_VERSION"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# PACKAGE INSTALLATION (Idempotent)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

install_packages() {
    log_section "Package Installation & System Update"
    
    log_info "Updating package manager cache..."
    apt-get update -y 2>&1 | tee -a "$LOG_FILE" || log_warn "apt-get update had issues (non-fatal)"

    REQUIRED_PACKAGES=(
        "apache2"
        "mariadb-server"
        "php"
        "php-mysql"
        "php-gd"
        "php-xml"
        "php-curl"
        "php-zip"
        "libapache2-mod-php"
        "git"
        "unzip"
        "curl"
        "wget"
    )

    log_info "Installing/updating required packages..."
    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        if dpkg -l | grep -q "^ii.*$pkg"; then
            log_info "  ✓ $pkg (already installed)"
        else
            log_info "  ↓ Installing $pkg..."
            apt-get install -y "$pkg" 2>&1 | tee -a "$LOG_FILE" || log_warn "Failed to install $pkg"
        fi
    done

    log_success "Package installation complete"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# SERVICE MANAGEMENT
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

enable_and_start_services() {
    log_section "Service Management"

    for service in apache2 mariadb; do
        log_info "Processing $service..."
        systemctl enable "$service" 2>&1 | tee -a "$LOG_FILE" || log_warn "Could not enable $service"
        
        if systemctl is-active --quiet "$service"; then
            log_success "$service already running"
        else
            log_info "Starting $service..."
            systemctl start "$service" 2>&1 | tee -a "$LOG_FILE" || log_error "Failed to start $service"
        fi
    done

    sleep 2  # Give services time to fully start
    log_success "Services ready"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# DATABASE SETUP (Fully Idempotent)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

setup_database() {
    log_section "Database Setup (Idempotent)"

    # Test MariaDB connection
    log_info "Testing MariaDB connection..."
    if ! mysql -u root -e "SELECT 1;" >/dev/null 2>&1; then
        log_error "Cannot connect to MariaDB. Attempting recovery..."
        systemctl restart mariadb
        sleep 3
        if ! mysql -u root -e "SELECT 1;" >/dev/null 2>&1; then
            log_error "MariaDB connection failed. Manual intervention required."
            return 1
        fi
    fi
    log_success "MariaDB connection OK"

    # Drop old database if it exists
    log_info "Checking for existing database '$DB_NAME'..."
    if mysql -u root -e "USE $DB_NAME;" 2>/dev/null; then
        log_warn "Database '$DB_NAME' found. Dropping it for clean reset..."
        mysql -u root -e "DROP DATABASE IF EXISTS $DB_NAME;" 2>&1 | tee -a "$LOG_FILE"
        log_success "Database dropped"
    else
        log_info "Database does not exist (fresh install)"
    fi

    # Drop old user if it exists
    log_info "Checking for existing user '$DB_USER'..."
    if mysql -u root -e "SELECT User FROM mysql.user WHERE User='$DB_USER';" 2>/dev/null | grep -q "$DB_USER"; then
        log_warn "User '$DB_USER' found. Dropping it..."
        mysql -u root -e "DROP USER IF EXISTS '$DB_USER'@'localhost';" 2>&1 | tee -a "$LOG_FILE"
        log_success "User dropped"
    else
        log_info "User does not exist (fresh install)"
    fi

    # Create fresh database and user
    log_info "Creating fresh database and user..."
    mysql -u root <<MYSQL_EOF 2>&1 | tee -a "$LOG_FILE"
CREATE DATABASE $DB_NAME;
CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
MYSQL_EOF

    log_success "Database setup complete"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# GIT CONFIGURATION & DVWA INSTALLATION
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

fix_git_safety() {
    log_section "Git Safety Fix"
    
    log_info "Setting git safe.directory for root..."
    git config --global --add safe.directory "$DVWA_DIR" 2>&1 | tee -a "$LOG_FILE" || true
    git config --global --add safe.directory "/var/www/html" 2>&1 | tee -a "$LOG_FILE" || true
    
    log_success "Git safety configured"
}

install_or_update_dvwa() {
    log_section "DVWA Installation/Update"

    # Create parent directory if needed
    if [ ! -d "/var/www/html" ]; then
        log_info "Creating /var/www/html..."
        mkdir -p "/var/www/html"
    fi

    # Handle existing DVWA installation
    if [ -d "$DVWA_DIR" ]; then
        if [ -d "$DVWA_DIR/.git" ]; then
            log_info "DVWA git repository found. Resetting and pulling latest..."
            cd "$DVWA_DIR"
            git reset --hard 2>&1 | tee -a "$LOG_FILE" || log_warn "git reset had issues"
            git pull 2>&1 | tee -a "$LOG_FILE" || log_warn "git pull had issues"
            log_success "DVWA updated"
        else
            log_warn "DVWA directory exists but is not a git repository. Removing and cloning fresh..."
            rm -rf "$DVWA_DIR"
            clone_dvwa
        fi
    else
        log_info "DVWA not found. Cloning fresh repository..."
        clone_dvwa
    fi
}

clone_dvwa() {
    log_info "Cloning DVWA from GitHub..."
    if git clone https://github.com/digininja/DVWA.git "$DVWA_DIR" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "DVWA cloned successfully"
    else
        log_error "Failed to clone DVWA. Check internet connection."
        return 1
    fi
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# PERMISSIONS SETUP
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

fix_permissions() {
    log_section "Permission Configuration"

    if [ ! -d "$DVWA_DIR" ]; then
        log_error "DVWA directory not found!"
        return 1
    fi

    log_info "Setting directory ownership to www-data:www-data..."
    chown -R www-data:www-data "$DVWA_DIR" 2>&1 | tee -a "$LOG_FILE"

    log_info "Setting directory permissions (755)..."
    find "$DVWA_DIR" -type d -exec chmod 755 {} \; 2>&1 | tee -a "$LOG_FILE"

    log_info "Setting file permissions (644)..."
    find "$DVWA_DIR" -type f -exec chmod 644 {} \; 2>&1 | tee -a "$LOG_FILE"

    log_info "Setting writable directories (770)..."
    chmod -R 770 "$DVWA_DIR/hackable/uploads" 2>&1 | tee -a "$LOG_FILE"
    chmod -R 770 "$DVWA_DIR/external/phpids/0.9/lib/IDS/tmp" 2>&1 | tee -a "$LOG_FILE" || true

    log_success "Permissions configured"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# DVWA CONFIGURATION
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

configure_dvwa() {
    log_section "DVWA Configuration"

    CONFIG_FILE="$DVWA_DIR/config/config.inc.php"

    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "Config file not found at $CONFIG_FILE"
        return 1
    fi

    # Backup config
    BACKUP_FILE="$CONFIG_FILE.bak.$(date +%s)"
    log_info "Backing up config to $BACKUP_FILE..."
    cp "$CONFIG_FILE" "$BACKUP_FILE"

    # Use sed to update config values (handles various formats)
    log_info "Updating database credentials..."
    
    # More robust sed patterns that handle different spacing
    sed -i "s/\$_DVWA\['db_user'\]\s*=\s*['\"][^'\"]*['\"]/\$_DVWA['db_user'] = '$DB_USER'/g" "$CONFIG_FILE"
    sed -i "s/\$_DVWA\['db_password'\]\s*=\s*['\"][^'\"]*['\"]/\$_DVWA['db_password'] = '$DB_PASS'/g" "$CONFIG_FILE"
    sed -i "s/\$_DVWA\['db_database'\]\s*=\s*['\"][^'\"]*['\"]/\$_DVWA['db_database'] = '$DB_NAME'/g" "$CONFIG_FILE"

    log_success "DVWA configuration updated"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# APACHE PHP CONFIGURATION
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

enable_php_module() {
    log_section "Apache PHP Module Configuration"

    log_info "Enabling required Apache modules..."
    
    for module in rewrite php mpm_prefork; do
        if a2enmod "$module" 2>&1 | grep -q "already enabled"; then
            log_info "  ✓ mod_$module already enabled"
        else
            log_info "  ✓ mod_$module enabled"
        fi
    done

    log_info "Checking PHP configuration..."
    # Enable error display for debugging (optional but helpful)
    PHP_INI=$(php -i 2>/dev/null | grep "Loaded Configuration File" | awk '{print $NF}')
    if [ -n "$PHP_INI" ] && [ -f "$PHP_INI" ]; then
        if ! grep -q "^display_errors = On" "$PHP_INI"; then
            log_info "Enabling PHP error display in php.ini..."
            sed -i 's/^display_errors = .*/display_errors = On/g' "$PHP_INI"
        fi
        if ! grep -q "^display_startup_errors = On" "$PHP_INI"; then
            log_info "Enabling PHP startup errors in php.ini..."
            sed -i 's/^display_startup_errors = .*/display_startup_errors = On/g' "$PHP_INI"
        fi
    fi

    log_success "PHP module configuration complete"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# SERVICE RESTART & VERIFICATION
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

restart_services() {
    log_section "Service Restart & Verification"

    log_info "Restarting Apache..."
    if systemctl restart apache2 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Apache restarted"
    else
        log_error "Apache restart failed"
        return 1
    fi

    sleep 2

    log_info "Verifying services..."
    systemctl is-active --quiet apache2 && log_success "Apache running" || log_error "Apache not running"
    systemctl is-active --quiet mariadb && log_success "MariaDB running" || log_error "MariaDB not running"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# FINAL SUMMARY
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

print_summary() {
    log_section "Installation Complete ✓"

    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  DVWA Auto Installer v$INSTALLER_VERSION - SUCCESS${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"

    echo -e "${BLUE}Installation Details:${NC}"
    echo -e "  Location:     ${GREEN}$DVWA_DIR${NC}"
    echo -e "  DB Name:      ${GREEN}$DB_NAME${NC}"
    echo -e "  DB User:      ${GREEN}$DB_USER${NC}"
    echo -e "  DB Password:  ${GREEN}$DB_PASS${NC}\n"

    echo -e "${BLUE}Access DVWA:${NC}"
    echo -e "  URL:          ${GREEN}http://localhost/dvwa${NC}"
    echo -e "  OR:           ${GREEN}http://127.0.0.1/dvwa${NC}"
    echo -e "  Username:     ${GREEN}admin${NC}"
    echo -e "  Password:     ${GREEN}password${NC}\n"

    echo -e "${YELLOW}Next Steps:${NC}"
    echo -e "  1. Open browser and go to: http://localhost/dvwa"
    echo -e "  2. Login with admin / password"
    echo -e "  3. Click 'Create / Reset Database' button"
    echo -e "  4. Set security level and start testing!\n"

    echo -e "${BLUE}Logs:${NC}"
    echo -e "  Full log saved to: ${GREEN}$LOG_FILE${NC}\n"

    echo -e "${BLUE}Troubleshooting:${NC}"
    echo -e "  • If you see a blank page, check PHP errors: tail $LOG_FILE"
    echo -e "  • If DB connection fails, verify MariaDB is running: systemctl status mariadb"
    echo -e "  • For permission issues: sudo chown -R www-data:www-data $DVWA_DIR\n"
}

error_exit() {
    log_error "$1"
    echo -e "\n${RED}Installation failed. Check log: $LOG_FILE${NC}"
    exit 1
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# MAIN EXECUTION FLOW
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

main() {
    clear
    echo -e "${BLUE}"
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║        DVWA Universal Auto Installer v$INSTALLER_VERSION          ║"
    echo "║    Production-Ready • Cross-Machine Compatible • Idempotent ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo -e "${NC}\n"

    root_check
    detect_system
    install_packages
    enable_and_start_services
    fix_git_safety
    setup_database || error_exit "Database setup failed"
    install_or_update_dvwa || error_exit "DVWA installation failed"
    fix_permissions
    configure_dvwa
    enable_php_module
    restart_services
    print_summary
}

# Trap errors
trap 'error_exit "Script interrupted or failed"' EXIT ERR
set -E

# Run main
main

exit 0
