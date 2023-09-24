#!/bin/bash

# Ellenőrizzük a szoftver telepítettségét
check_installed() {
	if [ ! -x "$(command -v $1)" ]; then
		echo "$2 még nincs telepítve. Telepítsd a szerverhez (apt-get install -y $1)."
		exit 1
	fi
}

# ProFtpd konfiguráció ellenőrzés
proftpd_config_check() {
	setting="$1"
	if ! grep -Fxq "$setting" /etc/proftpd/proftpd.conf; then
		echo "$setting" >> "/etc/proftpd/proftpd.conf"
		echo "$setting hozzáadva a konfigurációs fájlhoz."
	fi
}

proftpd_create_authuserfile() {
	file="$1"
	if [ ! -f "$file" ]; then
		touch "$file"
		chmod o-rwx "$file"
		echo "$file létrehozva"
	fi
}

# Ellenőrizzük a szükséges szoftverek telepítettségét
check_installed proftpd "A ProFTPD"
check_installed php "A PHP"
check_installed nginx "Az Nginx"
check_installed mysql "A MySQL"

# FTP szerver konfiguráció ellenőrzés
proftpd_config_check "DefaultRoot ~"
proftpd_config_check "RequireValidShell off"
proftpd_config_check "AuthUserFile /etc/proftpd/ftpd.passwd"
proftpd_config_check "AuthGroupFile /etc/proftpd/ftpd.group"
proftpd_config_check "AuthOrder mod_auth_file.c"

proftpd_create_authuserfile "/etc/proftpd/ftpd.passwd"
proftpd_create_authuserfile "/etc/proftpd/ftpd.group"

server_ip=$(hostname -I | awk '{print $1}')
uid_www_data=$(id -u www-data)

read -p "Add meg a domain nevet: " domain_nev

if ! dig +short $domain_nev | grep -q '^[.a-zA-Z0-9\-]*$'; then
	echo "A megadott '$domain_nev' domain név nem érvényes."
	exit 1
fi

# Először ellenőrizzük a domain IP címét
domain_ip=$(dig +short "${domain_nev}")

if [ "${domain_ip}" != "${server_ip}" ]; then
	echo "A domain név nincs az IP címre (${server_ip}) irányítva."
	exit 1
fi

read -p "Add meg a MySQL felhasználónevet: " mysql_user
echo "Add meg a MySQL jelszót: "
read -s mysql_password

# Létrehozás és beállítások
mkdir -p "/var/www/${domain_nev}"
chown -R www-data:www-data "/var/www/${domain_nev}"

# Ellenőrizze, hogy a felhasználó már létezik-e
if ! grep -q "${domain_nev}" /etc/proftpd/ftpd.passwd; then
	read -s -p "Add meg az FTP jelszót: " ftp_password
	echo

	echo -e "${ftp_password}\n${ftp_password}" | ftpasswd --passwd --stdin --file=/etc/proftpd/ftpd.passwd --name=${domain_nev} --uid=${uid_www_data} --gid=${uid_www_data} --home=/var/www/${domain_nev} --shell=/bin/false
	echo "Az FTP felhasználó hozzáadva."
else
 	echo "Az FTP felhasználó már létezik."
fi

systemctl restart proftpd

# Egyéb változók
nginx_config="/etc/nginx/sites-available/${domain_nev}.conf"
ssl_dir="/etc/letsencrypt/live/${domain_nev}"

# MySQL adatbázis és felhasználó létrehozása
mysql -e "CREATE DATABASE IF NOT EXISTS \`${domain_nev}\`"
mysql -e "CREATE USER IF NOT EXISTS '${mysql_user}'@'localhost' IDENTIFIED BY '${mysql_password}'"
mysql -e "GRANT ALL PRIVILEGES ON \`${domain_nev}\`.* TO '${mysql_user}'@'localhost'"
mysql -e "FLUSH PRIVILEGES"

# Nginx konfiguráció létrehozása
cat > "${nginx_config}" << EOF
server {
	listen 80;

	server_name ${domain_nev};
	root /var/www/${domain_nev}/public;

	index index.html index.htm index.php;

	access_log /var/log/nginx/${domain_nev}-access.log;
	error_log /var/log/nginx/${domain_nev}-error.log;

	location / {
		try_files \$uri \$uri/ /index.php?\$query_string;
	}

	location ~ \.php$ {
		fastcgi_pass unix:/var/run/php/php8.1-fpm.sock;
		include /etc/nginx/snippets/fastcgi-php.conf;
	}
}
EOF

ln -s "${nginx_config}" "/etc/nginx/sites-enabled/"

systemctl reload nginx

# SSL tanúsítvány létrehozása a Certbot-tal
if ! [[ -d /etc/letsencrypt/live/${domain_nev} ]]; then
	read -p "Add meg az e-mail címét a SSL tanúsítványhoz: " email_cim

	echo "SSL léterhozása..."
	echo

	certbot certonly --webroot -d "${domain_nev}" --email "${email_cim}" --agree-tos -w "/var/www/${domain_nev}"

	echo "SSL elkészült."
	echo
else
	echo "SSL már létezik ehhez a domainhez."
fi

# Nginx konfiguráció frissítése SSL-tanúsítvánnyal
sed -i "s/# server_name/server_name/g" "${nginx_config}"
sed -i 's/listen 80;/&\n\tlisten 443 ssl;/' "${nginx_config}"
sed -i "/listen 443 ssl/a \\\tssl_certificate ${ssl_dir}/fullchain.pem;" "${nginx_config}"
sed -i "/ssl_certificate/a \\\tssl_certificate_key ${ssl_dir}/privkey.pem;" "${nginx_config}"

# Nginx újraindítása
systemctl reload nginx

read -p "Kérem, adja meg a git projekt linkjet: " git_link
cd "/var/www/${domain_nev}"
git clone "${git_link}" .
git fetch
git checkout Server
composer i
php artisan optimize
