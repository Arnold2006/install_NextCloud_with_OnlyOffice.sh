#!/usr/bin/env bash
set -e

#############################################
# EDIT THESE VARIABLES
#############################################

DOMAIN="files.tera-sat.com"            # Domain name
DB_ROOT_PASSWORD="KziAQzSaAn9b#GXY"      # MariaDB root password
DB_NAME="nextcloud"                    # Nextcloud DB name
DB_USER="nc_user"                      # DB user
DB_PASS="xY4d!t77zcmyDB5m"            # DB user password
NC_ADMIN_USER="admin"                  # Nextcloud admin username
NC_ADMIN_PASS="NY46ZRTR90wwZZ"     # Nextcloud admin password

ONLYOFFICE_JWT="d4f8a9b7c2e1f6d3a5b9c8e7f2a1d6c3e8b4f0a7"  # Secret for OnlyOffice

#############################################
# DO NOT EDIT BELOW THIS LINE
#############################################

echo "=== Updating system ==="
apt update && apt upgrade -y

echo "=== Installing dependencies ==="
apt install -y software-properties-common apt-transport-https ca-certificates curl gnupg

echo "=== Installing NGINX ==="
apt install -y nginx

echo "=== Installing PHP 8.3 and required modules ==="
apt install -y php8.3 php8.3-fpm php8.3-cli php8.3-common php8.3-gd php8.3-mysql \
php8.3-curl php8.3-xml php8.3-zip php8.3-mbstring php8.3-bz2 php8.3-intl php8.3-gmp \
php8.3-imagick php8.3-bcmath php8.3-redis php8.3-fpm

echo "=== Installing MariaDB ==="
apt install -y mariadb-server mariadb-client

echo "=== Configuring MariaDB ==="
mysql -u root <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '$DB_ROOT_PASSWORD';
DELETE FROM mysql.user WHERE User='';
CREATE DATABASE $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

echo "=== Downloading Nextcloud ==="
cd /tmp
NEXTCLOUD_URL=$(curl -s https://api.github.com/repos/nextcloud/server/releases/latest | grep browser_download_url | grep zip | cut -d '"' -f 4)
wget $NEXTCLOUD_URL -O nextcloud.zip

echo "=== Installing Nextcloud ==="
apt install -y unzip
unzip nextcloud.zip -d /var/www/
mkdir -p /var/www/nextcloud/data
chown -R www-data:www-data /var/www/nextcloud

echo "=== Configuring NGINX for Nextcloud ==="
cat >/etc/nginx/sites-available/nextcloud.conf <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    root /var/www/nextcloud/;
    client_max_body_size 512M;
    fastcgi_buffers 64 4K;

    index index.php;

    location / {
        try_files \$uri \$uri/ /index.php\$request_uri;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

ln -sf /etc/nginx/sites-available/nextcloud.conf /etc/nginx/sites-enabled/nextcloud.conf
rm -f /etc/nginx/sites-enabled/default

echo "=== Installing OnlyOffice Document Server ==="
curl -sL https://download.onlyoffice.com/repo/onlyoffice.key | gpg --dearmor -o /usr/share/keyrings/onlyoffice.gpg
echo "deb [signed-by=/usr/share/keyrings/onlyoffice.gpg] https://download.onlyoffice.com/repo/debian/ squeeze main" \
    > /etc/apt/sources.list.d/onlyoffice.list

apt update
apt install -y onlyoffice-documentserver

echo "=== Configuring OnlyOffice JWT ==="
sed -i "s/\"secret\": \".*\"/\"secret\": \"$ONLYOFFICE_JWT\"/" /etc/onlyoffice/documentserver/local.json

echo "=== Configuring NGINX for OnlyOffice ==="
cat >/etc/nginx/sites-available/onlyoffice.conf <<EOF
server {
    listen 8080;
    server_name $DOMAIN;

    access_log /var/log/nginx/onlyoffice-access.log;
    error_log /var/log/nginx/onlyoffice-error.log;

    include /etc/nginx/includes/onlyoffice-documentserver.conf;
}
EOF

ln -sf /etc/nginx/sites-available/onlyoffice.conf /etc/nginx/sites-enabled/onlyoffice.conf

echo "=== Restarting services ==="
systemctl restart nginx
systemctl restart php8.3-fpm
systemctl restart mariadb
systemctl restart supervisor

echo "=== Finalizing Nextcloud installation ==="
/usr/bin/php /var/www/nextcloud/occ maintenance:install \
  --database "mysql" \
  --database-name "$DB_NAME" \
  --database-user "$DB_USER" \
  --database-pass "$DB_PASS" \
  --admin-user "$NC_ADMIN_USER" \
  --admin-pass "$NC_ADMIN_PASS"

echo "=== Enabling OnlyOffice plugin in Nextcloud ==="
sudo -u www-data php /var/www/nextcloud/occ app:install onlyoffice || true
sudo -u www-data php /var/www/nextcloud/occ app:enable onlyoffice

echo "=== Configuring OnlyOffice in Nextcloud ==="
sudo -u www-data php /var/www/nextcloud/occ config:system:set onlyoffice DocumentServerUrl --value="http://$DOMAIN:8080/"
sudo -u www-data php /var/www/nextcloud/occ config:system:set onlyoffice jwt_secret --value="$ONLYOFFICE_JWT"

echo "=== All Done! ==="
echo "You can now access Nextcloud at: http://$DOMAIN (HAProxy will provide HTTPS)"
