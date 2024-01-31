#!/bin/bash
###~ description: This script creates backups for easyengine sites and uploads them to a specified minio instance with mc (minio client)

#~ log file prefix
echo "=== ( $(date) - $HOSTNAME ) =========================================" >/tmp/eeBackup-errors.log

#~ redirect errors to file
exec 2>>/tmp/eeBackup-errors.log

#~ functions
alarm() {
	if [ "$SEND_ALARM" == "1" ]; then
		if [[ "$(cat /tmp/eeBackup-errors.log | sed '1d' | sed '/the input device.*/d; /^$/d' | wc -l)" != "0" ]]; then
			alarm_text='```\n'
			alarm_text+=$(cat /tmp/eeBackup-errors.log | sed '/the input device.*/d; /^$/d' | awk '{printf "%s\\n", $0}')
			alarm_text+='```'
			curl -fsSL -X POST -H "Content-Type: application/json" -d "{\"text\": \"$alarm_text\"}" "$ALARM_WEBHOOK_URL" 1>/dev/null
		fi
	fi
}

backup() {
	[[ -n $EXCLUDE ]] && EXCLUDE="$(echo ${EXCLUDE[@]} | sed 's/ /|/g')"
	[[ "$1" == "all" ]] && { sitelist=($(bash -c "ee site list --format=text ${EXCLUDE:+| grep -vE \"$EXCLUDE\"}")); } || { sitelist=($1); }
	for a in "${sitelist[@]}"; do
		tmpdir=$(mktemp -d)
		mkdir "$tmpdir/$a" && cd "$tmpdir/$a" || exit
		type=$(ee site info "$a" --format=json | jq -r '.site_type')

		local sitepath=/opt/easyengine/sites/$a
		[[ ! -d $sitepath ]] && { echo "Site $1 does not exists on /opt/easyengine/sites/"; return 1; }
		
		if [[ "$type" == "wp" ]]; then
			if [[ -e $sitepath/app/htdocs/wp-config.php ]]; then
				wpconfig=$sitepath/app/htdocs/wp-config.php
				versionfile=$sitepath/app/htdocs/wp-includes/version.php
				wpcontent=$sitepath/app/htdocs/wp-content
			elif [[ -e $sitepath/app/wp-config.php ]]; then
				wpconfig=$sitepath/app/wp-config.php
				versionfile=$sitepath/app/htdocs/wp-includes/version.php
				wpcontent=$sitepath/app/htdocs/wp-content
			fi
			
			[[ ! -e $wpconfig ]] && { echo "wp-config.php not found at $sitepath"; return 1; }

			ee shell "$a" --command="wp db export $a.sql"
			cp -a "$versionfile" "$wpconfig" "$wpcontent" "$sitepath/app/htdocs/$a.sql" .
			echo "ee_sitename=$a" >siteinfo.txt
			echo "ee_sitetype=$(ee site info "$a" --format=json | jq -r '.site_type')" >>siteinfo.txt
			echo "ee_siteroot=\$ee_sitename/wp-content" >>siteinfo.txt
			echo "ee_siteconfig=\$ee_sitename/wp-config.php" >>siteinfo.txt
			echo "ee_sitedb=\$ee_sitename/\$ee_sitename.sql" >>siteinfo.txt
			cd ..
			tar -czf "$a-$(date +%A).tar.gz" "$a"
			[[ "$NO_UPLOAD" == "1" ]] && cp "$a-$(date +%A).tar.gz" /root/ || mc cp "./$a-$(date +%A).tar.gz" "$MINIO_PATH/$HOSTNAME/$a/"

			if [[ $(date -d "yesterday" +%m) != $(date +%m) ]]; then
				tar -czf "$a-$(date -I).tar.gz" "$a"
				[[ "$NO_UPLOAD" == "1" ]] && cp "$a-$(date -I).tar.gz" /root/ || mc cp "./$a-$(date -I).tar.gz" "$MINIO_PATH/$HOSTNAME/$a/"
			fi
		elif [[ "$type" == "php" ]]; then
			cp -a "$sitepath/app/htdocs" .

			db_container=$(docker ps | grep services_global-db | awk '{print $1}')
			db_host=$(ee site info "$a" --format=json | jq -r '.db_host')
			db_name=$(ee site info "$a" --format=json | jq -r '.db_name')
			db_user=$(ee site info "$a" --format=json | jq -r '.db_user')
			db_password=$(ee site info "$a" --format=json | jq -r '.db_password')

			[[ "$db_host" != "null" ]] && withdb=1 || withdb=0
			[[ "$withdb" == "1" ]] && docker exec "$db_container" bash -c "mysqldump --no-create-db --opt --add-drop-table -Q -h $db_host -u $db_user -p$db_password $db_name" >"$tmpdir/$a/$a.sql"

			echo "ee_sitename=$a" >siteinfo.txt
			echo "ee_sitetype=$(ee site info "$a" --format=json | jq -r '.site_type')" >>siteinfo.txt
			echo "ee_siteroot=\$ee_sitename/htdocs" >>siteinfo.txt
			echo "ee_withdb=$withdb" >>siteinfo.txt

			cd ..
			tar -czf "$a-$(date +%A).tar.gz" "$a"
			[[ "$NO_UPLOAD" == "1" ]] && cp "$a-$(date +%A).tar.gz" /root/ || mc cp "./$a-$(date +%A).tar.gz" "$MINIO_PATH/$HOSTNAME/$a/"

			if [[ $(date -d "yesterday" +%m) != $(date +%m) ]]; then
				tar -czf "$a-$(date -I).tar.gz" "$a"
				[[ "$NO_UPLOAD" == "1" ]] && cp "$a-$(date -I).tar.gz" /root/ || mc cp "./$a-$(date -I).tar.gz" "$MINIO_PATH/$HOSTNAME/$a"
			fi
		elif [[ "$type" == "html" ]]; then
			cp -a "$sitepath/app/htdocs" .
			echo "ee_sitename=$a" >siteinfo.txt
			echo "ee_sitetype=$(ee site info "$a" --format=json | jq -r '.site_type')" >>siteinfo.txt
			echo "ee_siteroot=\$ee_sitename/htdocs" >>siteinfo.txt
			cd ..
			tar -czf "$a-$(date +%A).tar.gz" "$a"
			[[ "$NO_UPLOAD" == "1" ]] && cp "$a-$(date +%A).tar.gz" /root/ || mc cp "./$a-$(date +%A).tar.gz" "$MINIO_PATH/$HOSTNAME/$a/"

			if [[ $(date -d "yesterday" +%m) != $(date +%m) ]]; then
				tar -czf "$a-$(date -I).tar.gz" "$a"
				[[ "$NO_UPLOAD" == "1" ]] && cp "$a-$(date -I).tar.gz" /root/ || mc cp "./$a-$(date -I).tar.gz" "$MINIO_PATH/$HOSTNAME/$a"
			fi
		fi
		cd ~ || exit
		rm -rf "$tmpdir"
	done
}

checkconfig() {
	[[ ! -e $@ ]] && { echo "File \"$@\" does not exists, aborting..."; exit 1; }
	. "$@"

	local vars=(ALARM_WEBHOOK_URL MINIO_PATH SEND_ALARM)
	for a in "${vars[@]}"; do
		[[ -z ${!a} ]] && { echo "${a^} is not defined, aborting..."; return 1; }
	done
	return 0
}

checkcrontab() {
	[[ "$(id -u)" != "0" ]] && { echo "Please run this script with administrative privileges.."; return 1; }
	CRONCONFIG=$(crontab -u root -l | grep $(realpath "$0") | grep '^00 00')
	
	if [[ ! -n $CRONCONFIG ]]; then
		echo -e "Cron is not correctly configured\nPlease add this line in crontab:\n\n00 00 * * * $(realpath "$0") -b all"
		return 1
	else
		echo "Cron is already configured successfully."
		return 0
	fi
}

download() {
	list " " remote "[remote] Select site for restore process ($HOSTNAME)"
	printf "> "
	read sitename
	[[ -z $sitename ]] && return 1

	printf "\n"

	list " " remote "[remote] Select site for restore process \"$sitename\" ($HOSTNAME)" "$sitename"
	printf "%s" "$sitename> "
	read backupname
	[[ -z $backupname ]] && return 1

	mc cp "$MINIO_PATH/$HOSTNAME/$sitename/$backupname" ./
}

list() {
	if [[ "$2" == "local" ]]; then
		inventory=($(ee site list --format=text 2>&1 | sort))
		if [[ "${inventory[@]}" =~ "Error:" ]]; then
			count=1
		else
			count="$(echo "${inventory[@]}" | sed 's/ /\n/g' | wc -l)"
		fi
	elif [[ "$2" == "remote" ]]; then
		inventory=($(mc ls $MINIO_PATH/$HOSTNAME/${4:+$4} | sort | awk '{print $NF}' | sed 's|/||g'))
		count="$(echo "${inventory[@]}" | sed 's/ /\n/g' | wc -l)"
	else
		usage
		return 1
	fi

	[[ "$1" == "raw" ]] && { echo "${inventory[@]}" | sed 's/ /\n/g'; return 0; }

	OLDIFS=$IFS
	IFS=$'\n'

	title="# $3 #"
	for z in $(seq 1 ${#title}); do printf "#"; done
	printf "\n"
	echo "$title"
	for z in $(seq 1 ${#title}); do printf "#"; done
	printf "\n"
	[[ "${#inventory[@]}" == "0" ]] && { [[ -z "${inventory[0]}" ]] && { inventory=("Error: Site not found in MinIO, aborting..."); count="1"; emptyset=1;}; }
	for z in $(seq 0 $(("$count" - 1))); do
		printf "# %-$((${#title} - 4))s #\n" "${inventory[$z]}"
	done
	for z in $(seq 1 ${#title}); do printf "#"; done
	printf "\n"

	IFS=$OLDIFS

	[[ "$emptyset" == "1" ]] && exit 1
}

sync_status() {
	local_sites=$(list raw local)
	for site in ${local_sites[@]}; do
		today=$(date +"%Y-%m-%d")
		status=$(mc ls "$MINIO_PATH/$HOSTNAME/$site/" | grep -Po '(?<=^\[)([0-9]{4}-[0-9]{2}-[0-9]{2})' | tail -n 1)
		[[ -z "$status" ]] && { echo "\"$site\" backup is not found on MinIO"; continue; }

		if [[ "$today" == "$status" ]]; then
			echo "\"$site\" backup is up to date."
		else
			echo "\"$site\" backup is out of date. Latest backup date: $status"
		fi
	done
}

restore() {
	tmpdir=$(mktemp -d)
	
	[[ "$@" =~ "tar.gz" ]] && { backupname="$@"; } || { download; }
	cp -r $backupname $tmpdir/

	cd "$tmpdir" || exit

	tar -xzf "$backupname" -C $tmpdir

	. */siteinfo.txt
	[[ -z "$ee_sitename" ]] && { echo "Variable \"ee_sitename\" is not defined in siteinfo.txt, aborting..."; return 1; }

	[[ -d "/opt/easyengine/sites/$ee_sitename/backup" ]] && rm -rf "/opt/easyengine/sites/$ee_sitename/backup"
	mkdir "/opt/easyengine/sites/$ee_sitename/backup"

	if [[ "$ee_sitetype" == "wp" ]]; then
		if [[ -e "/opt/easyengine/sites/$ee_sitename/app/htdocs"/wp-config.php ]]; then
			wpconfig=("$ee_siteconfig" "/opt/easyengine/sites/$ee_sitename/app/htdocs/wp-config.php")
		elif [[ -e /opt/easyengine/sites/$ee_sitename/app/wp-config.php ]]; then
			wpconfig=("$ee_siteconfig" "/opt/easyengine/sites/$ee_sitename/app/wp-config.php")
		fi

		wpcontent=("$ee_siteroot" "/opt/easyengine/sites/$ee_sitename/app/htdocs/wp-content")

		ee shell "$ee_sitename" --command="wp db export $ee_sitename.backup.sql"
		mv "${wpconfig[1]}" "/opt/easyengine/sites/$ee_sitename/backup/"
		mv "${wpcontent[1]}" "/opt/easyengine/sites/$ee_sitename/backup/"
		mv "/opt/easyengine/sites/$ee_sitename/app/htdocs/$ee_sitename.backup.sql" "/opt/easyengine/sites/$ee_sitename/backup/"
		cp -ar "${wpconfig[0]}" "${wpconfig[1]}"
		cp -ar "${wpcontent[0]}" "${wpcontent[1]}"
		cp -ar "$ee_sitedb" "/opt/easyengine/sites/$ee_sitename/app/htdocs"
		ee shell "$ee_sitename" --command="wp db import $ee_sitename.sql"
	elif [[ "$ee_sitetype" == "html" ]]; then
		mv "/opt/easyengine/sites/$ee_sitename/app/htdocs" "/opt/easyengine/sites/$ee_sitename/backup/"
		cp -ar "$ee_siteroot" "/opt/easyengine/sites/$ee_sitename/app/"
	elif [[ "$ee_sitetype" == "php" ]]; then
		if [[ "$ee_withdb" == "1" ]]; then
			db_container=$(docker ps | grep services_global-db | awk '{print $1}')
			db_host=$(docker inspect services_global-db_1 | jq -r '.[].NetworkSettings.Networks."ee-global-backend-network".IPAddress')
			db_name=$(ee site info "$ee_sitename" --format=json | jq -r '.db_name')
			db_user=$(ee site info "$ee_sitename" --format=json | jq -r '.db_user')
			db_password=$(ee site info "$ee_sitename" --format=json | jq -r '.db_password')
			docker exec "$db_container" bash -c "mysqldump --no-create-db --opt --add-drop-table -Q -h $db_host -u $db_user -p$db_password $db_name" >"/opt/easyengine/sites/$ee_sitename/backup/$ee_sitename.backup.sql"
		fi
		mv "/opt/easyengine/sites/$ee_sitename/app/htdocs" "/opt/easyengine/sites/$ee_sitename/backup/"

		cp -ar "$ee_siteroot" "/opt/easyengine/sites/$ee_sitename/app/"
		[[ "$ee_withdb" == "1" ]] && mysql "$db_name" -h "$db_host" -u "$db_user" -p"$db_password" <"/opt/easyengine/sites/$ee_sitename/app/htdocs/$ee_sitename.sql"
	fi

	ee site clean "$ee_sitename"
	ee site restart "$ee_sitename"

	cd ~ || exit
	rm -rf "$tmpdir"
}

usage() {
	echo -e "Usage: $0 [-b <sitename>] [-c <config>] [-C] [-d] [-h] [-l <local|remote>] [-r <sitename>] [-s]"
	echo -e "\t-b | --backup  <all|sitename> : Backup <sitename> site or <all> sites."
	echo -e "\t-c | --config  <configfile>   : Use custom config file."
	echo -e "\t-C | --crontab                : Check crontab if cronjob exists."
	echo -e "\t-d | --download               : Download a backup from MinIO."
	echo -e "\t-h | --help                   : Shows this message."
	echo -e "\t-l | --list    <local|remote> : Shows site list <local|remote>ly."
	echo -e "\t-r | --restore <sitename>     : Restore <sitename> site."
	echo -e "\t-s | --syncstat               : Shows sync status."

}

main() {
	opt=($(getopt -l "backup:,config:,crontab,download,help,list:,restore:,syncstat" -o "b:,c:,C,d,h,l:,r:,s" -n "$0" -- "$@"))
	[[ "${#opt[@]}" == "1" ]] && { usage; exit 1; }
	eval set -- "${opt[@]}"

	CONFIG_PATH="/etc/eeBackup.conf"
	[[ "$1" == '-c' ]] || [[ "$1" == '--config' ]] && { [[ -n $2 ]] && CONFIG_PATH=$2; }
	checkconfig "$CONFIG_PATH" && . "$CONFIG_PATH"
	
	while true; do
		case $1 in
		-b | --backup)
			backup "$2"
			alarm
			break
			;;
		-C | --crontab)
			checkcrontab
			;;
		-d | --download)
			download
			;;
		-l | --list)
			list " " "$2" "[$2] List of sites for $HOSTNAME"
			;;
		-r | --restore)
			restore "$2"
			break
			;;
		-s | --syncstat)
			sync_status
			;;
		--)
			shift
			return 0
			;;
		-h | --help)
			usage
			break
			;;
		esac
		_status="$?"
		[[ "${_status}" != "0" ]] && { exit ${_status}; }
		shift
	done
}

main "$@"
