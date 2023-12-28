#!/bin/bash
###~ description: When disk fullness reaches a certain limit, it sends a notification to the specified url.

#~ variables
SCRIPT_VERSION="v2.1"
C_RED="\e[1;31m"
C_GREEN="\e[1;32m"
C_RESET="\e[0;39m"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"


#~ functions
checkconfig() {
	[[ ! -e $@ ]] && { echo "File \"$@\" does not exists, aborting..."; exit 1; }
	. "$@"

	local vars=(FILESYSTEMS THRESHOLD WEBHOOK_URL)
	for a in "${vars[@]}"; do
		[[ -z ${!a} ]] && { echo "${a^} is not defined, aborting..."; return 1; }
	done
	return 0
}


check() {
	local parts="$(df --output='source,fstype,target' | sed '1d' | sort | uniq | grep -E $(echo ${FILESYSTEMS[@]} | sed 's/ /|/g') | awk '$2 != "zfs" {print} $2 == "zfs" && $1 !~ /\//')"
	local oldifs=$IFS
	local json="["
	IFS=$'\n'
	for a in ${parts[@]}; do
		IFS=$oldifs info=($a)
		partition=${info[0]}
		filesystem=${info[1]}
		mountpoint=${info[2]}
		if [[ -n "$(echo $filesystem | grep -E 'ext4|ext3|ext2|xfs|nfs4')" ]]; then
			IFS=$oldifs stat=($(df -B1 --output="used,size,pcent" $mountpoint | sed '1d'))
			usage=${stat[0]}
			total=${stat[1]}
			percentage=${stat[2]}
		elif [[ -n "$(echo $filesystem | grep -E 'btrfs')" ]]; then
			usage=$(btrfs fi us -b $mountpoint | grep -P '^\s.+Used' | awk '{print $2}')
			total=$(btrfs fi us -b $mountpoint | grep -P 'Device size' | awk '{print $3}')
			percentage=$(echo "scale=2; $usage / $total * 100" | bc)
		elif [[ -n "$(echo $filesystem | grep -E 'zfs')" ]]; then
			if [[ "$(echo $filesystem | grep -E 'zfs')" == "fuse.zfs" ]]; then
				note="Fuse ZFS is not supported yet."
				usage="0"
				avail="0"
				total="0"
				percentage="0"
			else
				usage=$(zfs list -H -p -o used "$partition")
				avail=$(zfs list -H -p -o avail "$partition")
				total=$((usage + avail))
				percentage=$((usage * 100 / total))
			fi
 		fi
		[[ "$usage" != "0" ]] && usage=$(convertToProper $usage)
		[[ "$total" != "0" ]] && total=$(convertToProper $total)
		json+="{\"partition\":\"$partition\",\"filesystem\":\"$filesystem\",\"mountpoint\":\"$mountpoint\",\"percentage\":\"${percentage//%/}\",\"usage\":\"$usage\",\"total\":\"$total\", \"note\":\"${note:-OK}\"},"
	done
    json=${json/%,/}
    json+="]"
	IFS=$oldifs
	[[ "$@" == "report" ]] && report "$json" || { echo $json | jq; }
}


convertToProper() {
    value=$1
    dummy=$value
    for i in {0..7}; do
        if [[ ${dummy:0:1} == 0 ]]; then
            dummy=$((dummy * 1024))
			result=$(echo "scale=1; $value / 1024^($i-1)" | bc)
            case $i in
            1)
                result="${result}B"
			;;
            2)
                result="${result}KiB"
                ;;
            3)
                result="${result}MiB"
                ;;
            4)
                result="${result}GiB"
                ;;
            5)
                result="${result}TiB"
                ;;
            6)
                result="${result}PiB"
                ;;
            esac
            break
        else
            dummy=$((dummy / 1024))
        fi
    done
	echo $result
}


report() {
	local underthreshold=0
	[[ -n "$SERVER_NICK" ]] && alarm_hostname=$SERVER_NICK || alarm_hostname="$(hostname)"
	message="{\"text\": \"[ÇÖZÜLDÜ] - [ $alarm_hostname ] Bölüm kullanım seviyesi aşağıdaki bölümler için $THRESHOLD% seviyesinin altına indi;\n\`\`\`\n"
	table="$(printf '%-5s | %-10s | %-10s | %-50s | %s' '%' 'Used' 'Total' 'Partition' 'Mount Point')"
	table+='\n'
	for z in $(seq 1 110); do table+="$(printf '-')"; done
	local oldifs=$IFS
	IFS=$'\n'
	for info in $(echo $@ | jq -r ".[] | select(.percentage | tonumber < $THRESHOLD) | [.percentage, .usage, .total, .partition, .mountpoint] | @tsv"); do
		IFS=$oldifs a=($info)
		percentage=${a[0]}
		usage=${a[1]}
		total=${a[2]}
		partition=${a[3]}
		mountpoint=${a[4]}

		[[ "$mountpoint" == "/" ]] && mountpoint="/sys_root"
		[[ -f "/tmp/alarm_du/${mountpoint//\//_}" ]] && {
            table+="\n$(printf '%-5s | %-10s | %-10s | %-50s | %-35s' $percentage% $usage $total $partition ${mountpoint//sys_root/})"
            underthreshold=1
            rm -f /tmp/alarm_du/${mountpoint//\//_}
        }
	done
	message+="$table\n\`\`\`\"}"
	IFS=$oldifs
	#[[ "$underthreshold" == "1" ]] && echo $message || { echo "Underthreshold için bugün gönderilecek alarm yok..."; }
	[[ "$underthreshold" == "1" ]] && curl -X POST -H "Content-Type: application/json" -d "$message" "$WEBHOOK_URL" || { echo "Underthreshold için bugün gönderilecek alarm yok..."; }


	local overthreshold=0
	[[ -n "$SERVER_NICK" ]] && alarm_hostname=$SERVER_NICK || alarm_hostname="$(hostname)"
	message="{\"text\": \"[UYARI] - [ $alarm_hostname ] Bölüm kullanım seviyesi aşağıdaki bölümler için $THRESHOLD% seviyesinin üstüne çıktı;\n\`\`\`\n"
	table="$(printf '%-5s | %-10s | %-10s | %-50s | %s' '%' 'Used' 'Total' 'Partition' 'Mount Point')\n"
	for z in $(seq 1 110); do table+="$(printf '-')"; done
	local oldifs=$IFS
	IFS=$'\n'
	for info in $(echo $@ | jq -r ".[] | select(.percentage | tonumber > $THRESHOLD) | [.percentage, .usage, .total, .partition, .mountpoint] | @tsv"); do
		IFS=$oldifs a=($info)
		percentage=${a[0]}
		usage=${a[1]}
		total=${a[2]}
		partition=${a[3]}
		mountpoint=${a[4]}
		
		[[ "$mountpoint" == "/" ]] && mountpoint="/sys_root"
        if [[ -f "/tmp/alarm_du/${mountpoint//\//_}" ]]; then
			if [[ "$(cat /tmp/alarm_du/${mountpoint//\//_})" == "$(date +%Y-%m-%d)" ]]; then
				overthreshold=0
				continue
			else
				date +%Y-%m-%d > /tmp/alarm_du/${mountpoint//\//_}
				overthreshold=1
			fi
		else
			date +%Y-%m-%d > /tmp/alarm_du/${mountpoint//\//_}
			overthreshold=1
		fi
        table+="\n$(printf '%-5s | %-10s | %-10s | %-50s | %-35s' $percentage% $usage $total $partition ${mountpoint//sys_root/})"
	done
	message+="$table\n\`\`\`\"}"
	IFS=$oldifs
	#[[ "$overthreshold" == "1" ]] && echo $message || { echo "Overthreshold için bugün gönderilecek alarm yok..."; }
    [[ "$overthreshold" == "1" ]] && curl -X POST -H "Content-Type: application/json" -d "$message" "$WEBHOOK_URL" || { echo "Overthreshold için bugün gönderilecek alarm yok..."; }
}


usage() {
	echo -e "Usage: $0 [-c <configfile>] [-h] [-l] [-V] [-v]"
	echo -e "\t-c | --config   <configfile> : Use custom config file. (default: $CONFIG_PATH)"
	echo -e "\t-l | --list                  : List partition status."
	echo -e "\t-V | --validate              : Validate temporary directory and config."
	echo -e "\t-v | --version               : Print script version."
	echo -e "\t-h | --help                  : Print this message."
}


validate() {
	required_apps=("bc" "curl" "jq")
	missing_apps=""
	for a in ${required_apps[@]}; do 
			[[ ! -e "$(command -v $a)" ]] && missing_apps+="$a, "
	done
	[[ -n "$missing_apps" ]] && { echo -e "${C_RED}[ FAIL ] Please install this apps before proceeding: (${missing_apps%, })"; } || { echo -e "${C_GREEN}[  OK  ] Required apps are already installed."; }
	
	curl -fsSL $(echo $WEBHOOK_URL | grep -Po '(?<=\:\/\/)(([a-z]|\.)+)') &>/dev/null 
	[[ ! "$?" -eq "0" ]] && { echo -e "${C_RED}[ FAIL ] Webhook URL is not reachable."; } || { echo -e "${C_GREEN}[  OK  ] Webhook URL is reachable."; }

	touch /tmp/alarm_du/.testing
	[[ ! "$?" -eq "0" ]] && { echo -e "${C_RED}[ FAIL ] /tmp/alarm_du is not writable."; } || { echo -e "${C_GREEN}[  OK  ] /tmp/alarm_du is writable."; }
	
}


main() {
	mkdir -p /tmp/alarm_du

	opt=($(getopt -l "config:,help,list,validate,version" -o "c:,h,l,V,v" -n "$0" -- "$@"))
	eval set -- "${opt[@]}"

	CONFIG_PATH="/etc/alarm_du.conf"
	[[ "$1" == '-c' ]] || [[ "$1" == '--config' ]] && { [[ -n $2 ]] && CONFIG_PATH=$2; }
	[[ "$1" == '-d' ]] || [[ "$1" == '--debug'  ]] && { set +x; }
	checkconfig "$CONFIG_PATH" && . "$CONFIG_PATH"

	[[ "${#opt[@]}" == "1" ]] && { check "report"; exit 1; }
	
	while true; do
		case $1 in
			-l|--list)
				check
			;;
			-V|--validate)
				validate
			;;
			-v|--version)
				echo "Script Version: $SCRIPT_VERSION"
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
