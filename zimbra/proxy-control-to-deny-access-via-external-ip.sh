#!/bin/bash
###~ description: Applies patches to template file to prevent access to zimbra via IP address

#~ check zimbra
[[ -d "/opt/zimbra"  ]] && { ZIMBRA_PATH='/opt/zimbra' ; PRODUCT_NAME='zimbra'   ; }
[[ -d "/opt/zextras" ]] && { ZIMBRA_PATH='/opt/zextras'; PRODUCT_NAME='carbonio' ; }
[[ ! -n $ZIMBRA_PATH ]] && { echo "Zimbra not found in /opt, aborting..."; exit 1; }

#~ define variables
templatefile="$ZIMBRA_PATH/conf/nginx/templates/nginx.conf.https.default.template"
certfile="$ZIMBRA_PATH/ssl/$PRODUCT_NAME/server/server.crt"
keyfile="$ZIMBRA_PATH/ssl/$PRODUCT_NAME/server/server.key"
message="Hello World!"

#~ check template file and ip
[[ ! -e $templatefile ]] && { echo "File \"$templatefile\" not found, aborting..."; exit 1; }
[[ -e "$ZIMBRA_PATH/conf/nginx/external_ip.txt" ]] && ipaddress="$(cat $ZIMBRA_PATH/conf/nginx/external_ip.txt)" || ipaddress="$(curl -fsSL ifconfig.co)"

#~ define regex pattern and proxy block
regexpattern="\\n?(server\\s+?{\\n?\\s+listen\\s+443\\sssl\\shttp2;\\n?\\s+server_name\\n?\\s+$ipaddress;\\n?\\s+ssl_certificate\\s+$certfile;\\n?\\s+ssl_certificate_key\\s+$keyfile;\\n?\\s+location\\s+\\/\\s+{\\n?\\s+return\\s200\\s\'$message\';\\n?\\s+}\\n?})"
proxyblock="
server {
        listen                  443 ssl http2;
        server_name             $ipaddress;
        ssl_certificate         $certfile;
        ssl_certificate_key     $keyfile;
        location / {
                return 200 '$message';
        }
}"


#~ check block from templatefile
if [[ -n $(grep -Pzio "$regexpattern" $templatefile | tr '\0' '\n') ]]; then
	echo "Proxy control block exists on $templatefile file..."
	exit 1
else 
	echo "Adding proxy control block in $templatefile file..."
	echo -e "$proxyblock" >> $templatefile
	echo "Added proxy control block in $templatefile file..."
fi
