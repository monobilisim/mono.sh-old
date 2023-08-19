#!/bin/bash
###~ description: Used to add z-push setting to Zimbra template file

#~ check zimbra
[[ -d "/opt/zimbra"  ]] && { ZIMBRA_PATH='/opt/zimbra' ; PRODUCT_NAME='zimbra'   ; }
[[ -d "/opt/zextras" ]] && { ZIMBRA_PATH='/opt/zextras'; PRODUCT_NAME='carbonio' ; }
[[ ! -n $ZIMBRA_PATH ]] && { echo "Zimbra not found in /opt, aborting..."; exit 1; }

#~ define variables
templatefile="$ZIMBRA_PATH/conf/nginx/templates/nginx.conf.https.default.template"
[[ ! -e $templatefile ]] && { echo "File \"$templatefile\" not found, aborting..."; exit 1; }
[[ ! -e "/etc/nginx-php-fpm.conf" ]] && { echo "Z-Push not found in this server, aborting..."; exit 1; }
[[ -n $(grep "nginx-php-fpm.conf" $templatefile ]] && { echo "Z-Push config is already installed in \"$templatefile\""; exit 0; }

sed -i '/Microsoft-Server-ActiveSync/,/# For audit$/{
       /proxy_pass/ s/proxy_pass/### proxy_pass/
       /proxy_read_timeout/ s/proxy_read_timeout/### proxy_read_timeout/
       /proxy_buffering/ s/proxy_buffering/### proxy_buffering/
       /# For audit/ s/# For audit/# Z-PUSH start\n        include \/etc\/nginx-php-fpm.conf;\n        # Z-PUSH end\n\n        # For audit/
  }' $templatefile

echo "Added z-push settings in $templatefile, restarting zimbra proxy service..."
su - zimbra -c "zmproxyctl restart"
