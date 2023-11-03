#!/usr/bin/bash
###~ description: This script creates backups for easyengine sites and uploads them to a specified minio instance

# Needs xmllint(from libxml2-utils)

if [[ -f /etc/eeBackup.conf ]]; then
    . /etc/eeBackup.conf
else
    echo "Config file doesn't exists at /etc/eeBackup.conf"
    exit 1
fi


checkcrontab() {
	[[ "$(id -u)" != "0" ]] && { echo "Please run this script with administrative privileges.."; exit 1; }
	CRONCONFIG=$(crontab -l | grep $(realpath $0) | grep '^00 00')
	[[ ! -n $CRONCONFIG ]] && { echo -e "Cron is not correctly configured\nPlease add this line in crontab:\n\n00 00 * * * $(realpath $0) -b all"; exit 1; }
}

backup() {
    dateI=`date +%A`
    tempdir=$(mktemp -d)
    cd $tempdir
    
    sitepath=/opt/easyengine/sites/$1
    [[ ! -d $sitepath ]] && { echo site $1 does not exists at /opt/easyengine/sites/; return; }
    if [[ -e $sitepath/app/htdocs/wp-config.php ]]; then
        wpconfig=$sitepath/app/htdocs/wp-config.php
        versionfile=$sitepath/app/htdocs/wp-includes/version.php
        wpcontent=$sitepath/app/htdocs/wp-content
        staticsite=0
    elif [[ -e $sitepath/app/wp-config.php ]]; then
        wpconfig=$sitepath/app/wp-config.php
        versionfile=$sitepath/app/htdocs/wp-includes/version.php
        wpcontent=$sitepath/app/htdocs/wp-content
        staticsite=0
    else
        staticsite=1
    fi
    
    if [[ "$staticsite" == "1" ]]; then
        cp -r $sitepath/app/htdocs .
        tar -czf $1-${dateI}.tar.gz htdocs
        upload $dateI $1
        
        if [[ $(date -d "yesterday" +%m) != $(date +%m) ]]; then
            dateI=`date -I`            
            tar -czf $1-${dateI}.tar.gz htdocs
            upload $dateI $1
        fi
    else 
        if [[ ! -e $wpconfig ]]; then
        	echo wp-config.php file not found at $wpconfig
        	return
        fi

        DB_NAME=$(grep 'DB_NAME' $wpconfig | awk -F\' '{print $4}')
        DB_USER=$(grep 'DB_USER' $wpconfig | awk -F\' '{print $4}')
        DB_PASSWORD=$(grep 'DB_PASSWORD' $wpconfig | awk -F\' '{print $4}')
        DB_HOST=$(docker inspect services_global-db_1 | jq -r '.[].NetworkSettings.Networks."ee-global-backend-network".IPAddress')

        mysqldump $DB_NAME -h $DB_HOST -u $DB_USER -p$DB_PASSWORD > $1.sql

        cp -r $versionfile $wpconfig $wpcontent .

        tar -czf $1-${dateI}.tar.gz wp-config.php version.php wp-content $1.sql

        upload $dateI $1


        if [[ $(date -d "yesterday" +%m) != $(date +%m) ]]; then
            dateI=`date -I`
            tar -czf $1-${dateI}.tar.gz wp-config.php version.php wp-content $1.sql
            upload $dateI $1

        fi
    fi
    
    cd $HOME
    rm -rf $tempdir
}

upload() {
    dateR=`date -R`
    resource="/${MINIO_BUCKET}/$HOSTNAME/${2}/${2}-${1}.tar.gz"
    content_type="application/octet-stream"
    _signature="PUT\n\n${content_type}\n${dateR}\n${resource}"
    signature=`echo -en ${_signature} | openssl sha1 -hmac ${MINIO_SECRET_ACCESS_KEY} -binary | base64`

    echo ${2}
    curlout=$(curl -X PUT -T "${2}-${1}.tar.gz" \
              -H "Host: ${MINIO_HOST}" \
              -H "Date: ${dateR}" \
              -H "Content-Type: ${content_type}" \
              -H "Authorization: AWS ${MINIO_ACCESS_KEY_ID}:${signature}" \
              https://${MINIO_HOST}${resource} | xmllint --xpath "//Error/Message" - 2>/dev/null
            )
    [[ -n "$(echo $curlout | grep -io Message)" ]] && { curl -X POST -H "Content-Type: application/json" -d "{\"text\": \"Could not upload '${2}' to MinIO;\n\`\`\`\n$curlout\n\`\`\`\"}" "$ALARM_WEBHOOK_URL"; }
    echo =====================================
}

restore() {
    tempdir=$(mktemp -d)
    cp $1 $tempdir
    cd $tempdir

    tar xzf $(basename $1)
    sitename=$(ls *.sql | sed 's/\.sql//g')
    sitepath=/opt/easyengine/sites/$sitename
    [[ ! -d $sitepath ]] && { echo site $1 does not exists at /opt/easyengine/sites/; return; }


    wpconfig=$sitepath/app/wp-config.php
    versionfile=$sitepath/app/htdocs/wp-includes/version.php
    wpcontent=$sitepath/app/htdocs/wp-content

    if [[ ! -d $sitepath ]]; then
        echo Site does not exists
        exit 1
    fi

    [[ -d $sitepath/backup ]] && { rm -rf "$sitepath/backup"; }
    mkdir "$sitepath/backup"

    mv $wpconfig $wpcontent $sitepath/backup/
    mv wp-content $wpcontent
    mv wp-config.php $wpconfig

    cp *.sql /opt/easyengine/sites/example.com/app/htdocs
    ee shell $sitename --command="wp db import ${sitename}.sql"

    ee site clean $sitename
    ee site restart $sitename

    cd $HOME
    rm -rf $tempdir
}

checkvariable() {
    local arr=($@)
    for a in ${arr[@]}; do
        [[ ! -n ${!a} ]] && echo "${a^} is not defined" && exit 1
    done
}

main() {
    checkvariable MINIO_HOST MINIO_BUCKET MINIO_ACCESS_KEY_ID MINIO_SECRET_ACCESS_KEY
    checkcrontab

    case $1 in 
        -b|--backup)
            [[ "$2" == "all" ]] && { SITE_LIST=($(ee site list | grep enabled | awk '{print $1}')); } || { [[ -n "$2" ]] && { SITE_LIST=($(ls /opt/easyengine/sites | grep "^$2$")); }; }
	        checkvariable SITE_LIST
            for a in ${SITE_LIST[@]}; do
                backup $a
            done
        ;;
        -r|--restore)
            restore $2
        ;;
    esac
}

main "$@"