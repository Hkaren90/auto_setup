#!/bin/bash

echo "[+] Updating packages..."
sudo apt update -y

echo "[+] Installing Apache, MariaDB, and PHP..."
sudo apt install apache2 mariadb-server php php-mysqli php-gd php-xml php-curl php-zip libapache2-mod-php -y

echo "[+] Starting Apache and MariaDB..."
sudo systemctl enable apache2
sudo systemctl enable mariadb
sudo systemctl start apache2
sudo systemctl start mariadb

echo "[+] Securing MariaDB..."
sudo mysql -e "CREATE DATABASE dvwa;"
sudo mysql -e "CREATE USER 'dvwa'@'localhost' IDENTIFIED BY 'dvwa123';"
sudo mysql -e "GRANT ALL PRIVILEGES ON dvwa.* TO 'dvwa'@'localhost';"
sudo mysql -e "FLUSH PRIVILEGES;"

echo "[+] Cloning DVWA from GitHub..."
cd /var/www/html/
sudo rm -rf dvwa
sudo git clone https://github.com/digininja/DVWA.git dvwa
sudo chmod -R 777 /var/www/html/dvwa/

echo "[+] Copying config file..."
cd /var/www/html/dvwa/config/
sudo cp config.inc.php.dist config.inc.php

echo "[+] Updating DVWA configuration..."
sudo sed -i "s/'db_user'.*/'db_user' ] = 'dvwa';/" config.inc.php
sudo sed -i "s/'db_password'.*/'db_password' ] = 'dvwa123';/" config.inc.php

echo "[+] Restarting Apache..."
sudo systemctl restart apache2

echo "[+] DONE!"
echo "Open DVWA: http://127.0.0.1/dvwa"
