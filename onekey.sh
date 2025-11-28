bash <(curl -fsSL https://raw.githubusercontent.com/hulin-pro/vps-installer/main/onekey.sh)
#!/usr/bin/env bash
set -e
banner(){ echo -e "\n\033[1;36m==> $1\033[0m"; }
need_root(){ [ "$(id -u)" -ne 0 ] && echo "请用 root 运行" && exit 1; }

prompt(){
read -rp "VPS 名称: " VPS_NAME; VPS_NAME=${VPS_NAME:-MyVPS}
VNC_PORT=5905; VNC_DISPLAY=5
echo "VNC 端口固定: 5905"
while true; do
  read -rs -p "VNC 密码(6-8位): " VNC_PASS; echo
  read -rs -p "确认密码: " VNC_PASS2; echo
  [ "$VNC_PASS" != "$VNC_PASS2" ] && echo "不一致" && continue
  [ ${#VNC_PASS} -lt 6 ] || [ ${#VNC_PASS} -gt 8 ] && echo "长度错误" && continue
  break
done
read -rp "aaPanel 端口(默认8888): " AAP; AAP=${AAP:-8888}
read -rp "WordPress域名(可空): " WP_DOMAIN
[ -n "$WP_DOMAIN" ] && read -rp "SSL 邮箱(可空): " LE_EMAIL
}

expand(){
banner "磁盘扩容"
apt update -y; apt install -y cloud-guest-utils e2fsprogs
ROOT_DEV=$(findmnt -n -o SOURCE /)
DISK="/dev/vda"; PART="1"
echo "$ROOT_DEV"|grep -q "nvme0n1p1" && DISK="/dev/nvme0n1" && PART="p1"
growpart "$DISK" "${PART#p}"||true
resize2fs "${DISK}${PART}"||true
}

vnc(){
banner "安装 GUI + VNC"
apt install -y xfce4 xfce4-goodies tightvncserver xorg dbus-x11 wget curl git nano expect
tightvncserver ":$VNC_DISPLAY"||true
tightvncserver -kill ":$VNC_DISPLAY"||true
mkdir -p /root/.vnc
cat >/root/.vnc/xstartup <<EOF
#!/bin/sh
xrdb \$HOME/.Xresources
startxfce4 &
EOF
chmod +x /root/.vnc/xstartup
cat >/root/setvncpass.expect<<EOF
#!/usr/bin/expect -f
set timeout -1
set vpass [lindex \$argv 0]
spawn vncpasswd
expect "Password:"
send "\$vpass\r"
expect "Verify:"
send "\$vpass\r"
expect { "view-only password" { send "n\r" } timeout {} }
expect eof
EOF
chmod +x /root/setvncpass.expect
/root/setvncpass.expect "$VNC_PASS"
cat >/etc/systemd/system/vnc@.service<<EOF
[Unit]
Description=VNC %i ($VPS_NAME)
After=network.target
[Service]
Type=forking
User=root
PAMName=login
PIDFile=/root/.vnc/%H:%i.pid
ExecStart=/usr/bin/tightvncserver %i
ExecStop=/usr/bin/tightvncserver -kill %i
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable vnc@:$VNC_DISPLAY
systemctl restart vnc@:$VNC_DISPLAY
}

apps(){
banner "Chrome VSCode"
wget -O /tmp/ch.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
apt install -y /tmp/ch.deb||apt -f install -y
wget -O /tmp/vs.deb https://go.microsoft.com/fwlink/?LinkID=760868
apt install -y /tmp/vs.deb||apt -f install -y
}

docker_install(){
banner "Docker"
apt-get update -y
apt-get install -y ca-certificates gnupg lsb-release
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg|gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo \$UBUNTU_CODENAME) stable" >/etc/apt/sources.list.d/docker.list
apt update -y
apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable docker --now
docker volume create portainer_data>/dev/null
docker run -d --name portainer --restart=always -p 9443:9443 -p 8000:8000 -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:latest
}

aap(){
banner "aaPanel"
wget -O a.sh http://www.aapanel.com/script/install-ubuntu_6.0_en.sh
bash a.sh<<EOF
y
EOF
[ -f /www/server/panel/data/port.pl ] && echo "$AAP" >/www/server/panel/data/port.pl && /etc/init.d/bt restart||true
}

lnmp(){
banner "LNMP"
apt install -y nginx mariadb-server
systemctl enable nginx --now
mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '';"||true
apt install -y php-fpm php-mysql php-cli php-curl php-xml php-zip php-gd php-mbstring php-intl
apt install -y python3 python3-pip
}

wp(){
[ -z "$WP_DOMAIN" ]&&return
banner "WordPress + SSL"
apt install -y wget tar certbot python3-certbot-nginx
DBN="wpdb"; DBU="wpuser"; DBP=$(openssl rand -hex 8)
mysql -e "CREATE DATABASE $DBN;"
mysql -e "CREATE USER '$DBU'@'localhost' IDENTIFIED BY '$DBP';"
mysql -e "GRANT ALL PRIVILEGES ON $DBN.* TO '$DBU'@'localhost'; FLUSH PRIVILEGES;"
mkdir -p /var/www/$WP_DOMAIN
wget -qO /tmp/wp.tgz https://wordpress.org/latest.tar.gz
tar -xzf /tmp/wp.tgz -C /tmp
rsync -a /tmp/wordpress/ /var/www/$WP_DOMAIN/
chown -R www-data:www-data /var/www/$WP_DOMAIN
cp /var/www/$WP_DOMAIN/wp-config-sample.php /var/www/$WP_DOMAIN/wp-config.php
sed -i "s/database_name_here/$DBN/" /var/www/$WP_DOMAIN/wp-config.php
sed -i "s/username_here/$DBU/" /var/www/$WP_DOMAIN/wp-config.php
sed -i "s/password_here/$DBP/" /var/www/$WP_DOMAIN/wp-config.php
cat >/etc/nginx/sites-available/$WP_DOMAIN<<EOF
server {
  listen 80;
  server_name $WP_DOMAIN;
  root /var/www/$WP_DOMAIN;
  index index.php index.html;
  location / { try_files \$uri \$uri/ /index.php?\$args; }
  location ~ \.php$ {
    include snippets/fastcgi-php.conf;
    fastcgi_pass unix:/run/php/php-fpm.sock;
  }
}
EOF
ln -sf /etc/nginx/sites-available/$WP_DOMAIN /etc/nginx/sites-enabled/$WP_DOMAIN
nginx -t && systemctl reload nginx
EMAIL=${LE_EMAIL:-"admin@$WP_DOMAIN"}
certbot --nginx -d "$WP_DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --redirect
}

ufw(){
banner "UFW"
apt install -y ufw
ufw allow 22; ufw allow 80; ufw allow 443
ufw allow 5905; ufw allow $AAP; ufw allow 9443
yes | ufw enable||true
}

summary(){
IP=$(hostname -I|awk '{print $1}')
echo "=== Done ==="
echo "VNC: $IP:5905"
echo "aaPanel: http://$IP:$AAP"
echo "Portainer: https://$IP:9443"
[ -n "$WP_DOMAIN" ] && echo "WP: https://$WP_DOMAIN/"
}

need_root
prompt
expand
vnc
apps
docker_install
aap
lnmp
wp
ufw
summary
