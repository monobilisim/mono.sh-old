#!/bin/bash
###~ description: setup script for caddy server

#~ check caddy
[[ -n $(command -v caddy) ]] && { echo "Caddyserver already installed"; exit 0; }


#~ check required apps
REQUIRED_APPS=('curl' 'wget' 'tar')
for a in ${REQUIRED_APPS[@]}; do
	[[ ! -e $(command -v $a) ]] && { echo "Please install \"$a\" before proceeding..."; exit 1; }
done


#~ check remote version
REMOTE_VERSION="$(curl -fsSL https://api.github.com/repos/caddyserver/caddy/tags | jq -r '.[].name' | sort -Vr | head -n 1)"


#~ install caddyserver
cd $(mktemp -d)
wget -q "https://github.com/caddyserver/caddy/releases/download/${REMOTE_VERSION}/caddy_${REMOTE_VERSION//v/}_linux_amd64.tar.gz"
tar xzvf caddy_*.tar.gz
mv caddy /usr/bin/
chmod +x /usr/bin/caddy


#~ update caddy and install modules
caddy upgrade
caddy add-package github.com/caddy-dns/cloudflare
caddy add-package github.com/porech/caddy-maxmind-geolocation


#~ create users and groups
groupadd --system caddy
useradd --system --gid caddy --create-home --home-dir /var/lib/caddy --shell /usr/sbin/nologin --comment "Caddy Web Server" caddy
usermod -aG www-data caddy
usermod -aG caddy www-data
usermod -aG apache caddy
usermod -aG caddy apache
usermod -aG nginx caddy
usermod -aG caddy nginx


#~ install system service
if [[ ! -n "$(command -v systemctl)" ]]; then
	wget -q https://raw.githubusercontent.com/monobilisim/mono.sh/main/.bin/caddy-sysv.service -O /etc/init.d/caddy
	chmod +x /etc/init.d/caddy
else
	wget -q https://raw.githubusercontent.com/caddyserver/dist/master/init/caddy.service -O /etc/systemd/system/caddy.service
	systemctl daemon-reload
	systemctl enable caddy
fi


#~ install example config
mkdir -p /etc/caddy/ssl
wget -q https://raw.githubusercontent.com/caddyserver/dist/master/config/Caddyfile -O /etc/caddy/Caddyfile
