#!/bin/bash
set -euo pipefail

INSTALLER_VERSION="2.1-clean"
DVWA_DIR="/var/www/html/dvwa"
DB_USER="dvwa"
DB_PASS="password"
DB_NAME="dvwa"
LOG_FILE="/tmp/dvwa_installer_$(date +%s).log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[ℹ]${NC} $1" | tee -a "$LOG_FILE"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1" | tee -a "$LOG_FILE"; }
log_warn()    { echo -e "${YELLOW}[⚠]${NC} $1" | tee -a "$LOG_FILE"; }
log_error()   { echo -e "${RED}[✗]${NC} $1" | tee -a "$LOG_FILE"; }

error_exit() {
    log_error "$1"
    echo -e "\n${RED}Installation failed. Check log: $LOG_FILE${NC}"
    exit 1
}

root_check() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Run as root (use: sudo)"
        exit 1
    fi
}

install_packages() {
    log_info "Updating apt cache..."
    apt-get update -y || log_warn "apt-get update warning (non-fatal)"

    local pkgs=(
        apache2
        mariadb-server
        php
        php-mysql
        php-gd
        php-xml
        php-curl
        php-zip
        libapache2-mod-php
        git
        unzip
        curl
        wget
    )

    log_info "Installing required packages (idempotent)..."
    for p in "${pkgs[@]}"; do
        if dpkg -l | grep -q "^ii\s\+$p"; then
            log_info "$p already installed"
        else
            log_info "Installing $p..."
            apt-get install -y "$p" || log_warn "Failed to install $p"
        fi
    done
    log_success "Packages installed"
}

enable_and_start_services() {
    log_info "Enabling and starting Apache & MariaDB..."
    for svc in apache2 mariadb; do
        systemctl enable "$svc" || log_warn "Could not enable $svc"
        systemctl restart "$svc" || log_error "Failed to start $svc"
    done
    sleep 2
    log_success "Services running"
}

clean_database() {
    log_info "Cleaning any existing DVWA database/user..."

    if ! mysql -u root -e "SELECT 1;" >/dev/null 2>&1; then
        log_error "Cannot connect to MariaDB as root (no password). If root has a password, edit this script to use -p."
        exit 1
    fi

    mysql -u root <<EOF || true
DROP DATABASE IF EXISTS \`$DB_NAME\`;
DROP USER IF EXISTS '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

    log_success "Old DVWA DB and user removed (if they existed)"
}

create_database() {
    log_info "Creating fresh DVWA database and user..."
    mysql -u root <<EOF
CREATE DATABASE $DB_NAME;
CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF
    log_success "DVWA database and user created"
}

clean_dvwa_dir() {
    log_info "Removing old DVWA directory if present..."
    rm -rf "$DVWA_DIR"
    mkdir -p "$(dirname "$DVWA_DIR")"
    log_success "DVWA directory cleaned"
}

clone_dvwa() {
    log_info "Cloning DVWA from GitHub..."
    git config --global --add safe.directory "$DVWA_DIR" || true
    git config --global --add safe.directory "/var/www/html" || true

    if git clone https://github.com/digininja/DVWA.git "$DVWA_DIR"; then
        log_success "DVWA cloned"
    else
        error_exit "Failed to clone DVWA (check internet connection)"
    fi
}

fix_permissions() {
    log_info "Fixing DVWA permissions..."
    chown -R www-data:www-data "$DVWA_DIR"

    find "$DVWA_DIR" -type d -exec chmod 755 {} \;
    find "$DVWA_DIR" -type f -exec chmod 644 {} \;

    chmod -R 770 "$DVWA_DIR/hackable/uploads" || true
    chmod -R 770 "$DVWA_DIR/external/phpids/0.9/lib/IDS/tmp" || true

    log_success "Permissions fixed"
}

configure_dvwa() {
    log_info "Configuring DVWA config.inc.php..."
    local cfg="$DVWA_DIR/config/config.inc.php"

    if [[ ! -f "$cfg" ]]; then
        error_exit "Config file not found: $cfg"
    fi

    cp "$cfg" "$cfg.bak.$(date +%s)"

    sed -i "s/\$_DVWA\['db_user'\]\s*=\s*['\"][^'\"]*['\"]/\\\$_DVWA['db_user'] = '$DB_USER'/g" "$cfg"
    sed -i "s/\$_DVWA\['db_password'\]\s*=\s*['\"][^'\"]*['\"]/\\\$_DVWA['db_password'] = '$DB_PASS'/g" "$cfg"
    sed -i "s/\$_DVWA\['db_database'\]\s*=\s*['\"][^'\"]*['\"]/\\\$_DVWA['db_database'] = '$DB_NAME'/g" "$cfg"

    log_success "DVWA config updated"
}

enable_php_module() {
    log_info "Enabling Apache PHP-related modules..."
    for m in rewrite php mpm_prefork; do
        a2enmod "$m" >/dev/null 2>&1 || true
    done
    log_success "Apache modules enabled (where available)"
}

restart_services() {
    log_info "Restarting Apache..."
    systemctl restart apache2 || error_exit "Apache restart failed"
    sleep 2
    log_success "Apache restarted"
}

print_summary() {
    echo
    echo -e "${GREEN}DVWA install complete (fresh clean setup).${NC}"
    echo
    echo "Location:      $DVWA_DIR"
    echo "DB Name:       $DB_NAME"
    echo "DB User:       $DB_USER"
    echo "DB Password:   $DB_PASS"
    echo
    echo "Open in browser:"
    echo "  http://127.0.0.1/dvwa"
    echo
    echo "Web login:"
    echo "  Username: admin"
    echo "  Password: password"
    echo
    echo "Then click 'Create / Reset Database' in the DVWA UI."
    echo
    echo "Log file: $LOG_FILE"
}

main() {
    root_check
    install_packages
    enable_and_start_services
    clean_database
    create_database
    clean_dvwa_dir
    clone_dvwa
    fix_permissions
    configure_dvwa
    enable_php_module
    restart_services
    print_summary
}

trap 'error_exit "Script interrupted or failed"' EXIT ERR
set -E
main
