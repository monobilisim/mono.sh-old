#!/usr/bin/env bash
###~ description: This script is used to check the health of the server
#~ variables
script_version="v3.3.2"

if [[ "$CRON_MODE" == "1" ]]; then
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

    color_red=""
    color_green=""
    color_yellow=""
    color_blue=""
    color_reset=""

    #~ log file prefix
    echo "=== ( $(date) - $HOSTNAME ) =========================================" >/tmp/monocloud-health.log

    #~ redirect all outputs to file
    exec &>>/tmp/monocloud-health.log
else
    color_red=$(tput setaf 1)
    color_green=$(tput setaf 2)
    color_yellow=$(tput setaf 3)
    color_blue=$(tput setaf 4)
    color_reset=$(tput sgr0)
fi

mkdir -p /tmp/monocloud-health

grep_custom() {
    if command -v pcregrep &>/dev/null; then
	pcregrep $@
    else
	grep -P $@
    fi
}

#~ check configuration file
check_config_file() {
    [[ ! -f "$@" ]] && {
        echo "File \"$@\" does not exist, exiting..."
        exit 1
    }
    . "$@"
    local required_vars=(FILESYSTEMS PART_USE_LIMIT LOAD_LIMIT RAM_LIMIT WEBHOOK_URL REDMINE_URL REDMINE_API_KEY)
    for var in "${required_vars[@]}"; do
        [[ -z "${!var}" ]] && {
            echo "Variable \"$var\" is not set in \"$@\". exiting..."
            exit 1
        }
    done
    return 0
}

function alarm() {
    if [ -z "$ALARM_WEBHOOK_URLS" ]; then
        curl -fsSL -X POST -H "Content-Type: application/json" -d "{\"text\": \"$1\"}" "$WEBHOOK_URL" 1>/dev/null
    else
        for webhook in "${ALARM_WEBHOOK_URLS[@]}"; do
            curl -fsSL -X POST -H "Content-Type: application/json" -d "{\"text\": \"$1\"}" "$webhook" 1>/dev/null
        done
    fi

    if [ "$SEND_DM_ALARM" = "1" ] && [ -n "$ALARM_BOT_API_KEY" ] && [ -n "$ALARM_BOT_EMAIL" ] && [ -n "$ALARM_BOT_API_URL" ] && [ -n "$ALARM_BOT_USER_EMAILS" ]; then
        for user_email in "${ALARM_BOT_USER_EMAILS[@]}"; do
            curl -s -X POST "$ALARM_BOT_API_URL"/api/v1/messages \
                -u "$ALARM_BOT_EMAIL:$ALARM_BOT_API_KEY" \
                --data-urlencode type=direct \
                --data-urlencode "to=$user_email" \
                --data-urlencode "content=$1" 1>/dev/null
        done
    fi
}

function get_time_diff() {
    [[ -z $1 ]] && {
        echo "Service name is not defined"
        return
    }
    service_name=$1
    service_name=$(echo "$service_name" | sed 's#/#-#g')
    file_path="/tmp/monocloud-health/monocloud_${service_name}_status.txt"

    if [ -f "${file_path}" ]; then

	old_date=$(awk '{print $1, $2}' <"${file_path}")
	old=$(date -j -f "%Y-%m-%d %H:%M" "$old_date" "+%s")
	new=$(date -j -f "%Y-%m-%d %H:%M" "$(date '+%Y-%m-%d %H:%M')" "+%s")

        time_diff=$(((new - old) / 60))

        if ((time_diff >= ALARM_INTERVAL)); then
            date "+%Y-%m-%d %H:%M" >"${file_path}"
        fi
    else
        date "+%Y-%m-%d %H:%M" >"${file_path}"
        time_diff=0
    fi

    echo $time_diff
}

function alarm_check_down() {
    [[ -z $1 ]] && {
        echo "Service name is not defined"
        return
    }
    service_name=${1//\//-}
    file_path="/tmp/monocloud-health/monocloud_${service_name}_status.txt"
    [[ -n "$SERVER_NICK" ]] && alarm_hostname=$SERVER_NICK || alarm_hostname="$(hostname)"

    if [ -z $3 ]; then
        if [ -f "${file_path}" ]; then
            old_date=$(awk '{print $1}' <"$file_path")
            current_date=$(date "+%Y-%m-%d")
            if [ "${old_date}" != "${current_date}" ]; then
                date "+%Y-%m-%d %H:%M" >"${file_path}"
                alarm "[Mono Cloud - $alarm_hostname] [:red_circle:] $2"
            fi
        else
            date "+%Y-%m-%d %H:%M" >"${file_path}"
            alarm "[Mono Cloud - $alarm_hostname] [:red_circle:] $2"
        fi
    else
        if [ -f "${file_path}" ]; then
            old_date=$(awk '{print $1}' <"$file_path")
            [[ -z $(awk '{print $3}' <"$file_path") ]] && locked=false || locked=true
            current_date=$(date "+%Y-%m-%d")
            if [ "${old_date}" != "${current_date}" ]; then
                date "+%Y-%m-%d %H:%M locked" >"${file_path}"
                alarm "[Mono Cloud - $alarm_hostname] [:red_circle:] $2"
            else
                if ! $locked; then
                    time_diff=$(get_time_diff "$1")
                    if ((time_diff >= ALARM_INTERVAL)); then
                        date "+%Y-%m-%d %H:%M locked" >"${file_path}"
                        alarm "[Mono Cloud - $alarm_hostname] [:red_circle:] $2"
                        if [ $3 == "service" ]; then
                            check_active_sessions
                        fi
                    fi
                fi
            fi
        else
            date "+%Y-%m-%d %H:%M" >"${file_path}"
        fi
    fi
}

function alarm_check_up() {
    [[ -z $1 ]] && {
        echo "Service name is not defined"
        return
    }
    service_name=${1//\//-}
    file_path="/tmp/monocloud-health/monocloud_${service_name}_status.txt"
    [[ -n "$SERVER_NICK" ]] && alarm_hostname=$SERVER_NICK || alarm_hostname="$(hostname)"

    # delete_time_diff "$1"
    if [ -f "${file_path}" ]; then
        if [ -z $3 ]; then
            rm -rf "${file_path}"
            alarm "[Mono Cloud - $alarm_hostname] [:check:] $2"
        else
            [[ -z $(awk '{print $3}' <"$file_path") ]] && locked=false || locked=true
            rm -rf "${file_path}"
            if $locked; then
                alarm "[Mono Cloud - $alarm_hostname] [:check:] $2"
            fi
        fi
    fi
}

function check_active_sessions() {
    active_sessions=($(ls /var/run/ssh-session))
    if [[ ${#active_sessions[@]} == 0 ]]; then
        return
    else
        for session in "${active_sessions[@]}"; do
            user=$(jq -r .username /var/run/ssh-session/"$session")
            alarm_check_down "session_$session" "User *$user* is connected to host"
        done
    fi
}

#~ check partitions
check_partitions() {
    local partitions="$(df -l -T | awk '{print $1,$2,$7}' | sed '1d' | sort | uniq | grep -E $(echo ${FILESYSTEMS[@]} | sed 's/ /|/g') | awk '$2 != "zfs" {print} $2 == "zfs" && $1 !~ /\//')"
    oldIFS=$IFS
    local json="["
    IFS=$'\n'
    for partition in $partitions; do
        IFS=$oldIFS info=($partition)
        local partition="${info[0]}"
        local filesystem="${info[1]}"
        local mountpoint="${info[2]}"
        if [[ "${FILESYSTEMS[@]}" =~ "$filesystem" ]]; then
            case $filesystem in
		"fuse.zfs")
		    note="Fuse ZFS is not supported yet."
		    usage="0"
		    avail="0"
		    total="0"
		    percentage="0"
		    ;;
		"zfs")
		    usage=$(zfs list -H -p -o used "$partition")
		    avail=$(zfs list -H -p -o avail "$partition")
		    total=$((usage + avail))
		    percentage=$((usage * 100 / total))
		    ;;
		"btrfs")
		    usage=$(btrfs fi us -b $mountpoint | grep_custom '^\s.+Used' | awk '{print $2}')
		    total=$(btrfs fi us -b $mountpoint | grep_custom 'Device size' | awk '{print $3}')
		    percentage=$(echo "scale=2; $usage / $total * 100" | bc)
		    ;;
		*)
		    stat=($(df -P $mountpoint | sed '1d' | awk '{printf "%s %-12s   %s\n", $3*1024, $2*1024, $5}'))
		    usage=${stat[0]}
		    total=${stat[1]}
		    percentage=${stat[2]}
		    ;;
	    esac
        fi
        [[ "$usage" != "0" ]] && usage=$(convertToProper $usage)
        [[ "$total" != "0" ]] && total=$(convertToProper $total)
        json+="{\"partition\":\"$partition\",\"filesystem\":\"$filesystem\",\"mountpoint\":\"$mountpoint\",\"percentage\":\"${percentage//%/}\",\"usage\":\"$usage\",\"total\":\"$total\", \"note\":\"${note:-OK}\"},"
    done
    json=${json/%,/}
    json+="]"
    IFS=$oldifs
    echo $json
}

function sum_array() {
	local sum=0
	for num in $@; do
		sum=$(echo "$sum + $num" | bc)
	done
	echo $sum
}

function dynamic_limit() {
    [[ "$DYNAMIC_LIMIT_INTERVAL" -lt 1 ]] && return
    
    [ -d "/tmp/monocloud-health/checks" ] || return
    cd /tmp/monocloud-health/checks
    
    LOAD_LIMIT_ARRAY=()
    RAM_LIMIT_ARRAY=()
    
    if [ -f "/tmp/monocloud-health/checks/last_ram_limit_dynamic" ]; then
	export RAM_LIMIT_DYNAMIC="$(cat /tmp/monocloud-health/checks/last_ram_limit_dynamic)"
    fi

    if [ -f "/tmp/monocloud-health/checks/last_load_limit_dynamic" ]; then
	export LOAD_LIMIT_DYNAMIC="$(cat /tmp/monocloud-health/checks/last_load_limit_dynamic)"
    fi

    if [[ $(ls -1 *.json | wc -l) -ge $DYNAMIC_LIMIT_INTERVAL ]]; then
       for file in *.json; do
           LOAD_LIMIT_ARRAY+=( $(jq -r '.load' $file) )
           RAM_LIMIT_ARRAY+=( $(jq -r '.ram' $file) )
       done
	
       # Get the average of the array
       export LOAD_LIMIT_DYNAMIC=$(echo "scale=2; ($(sum_array ${LOAD_LIMIT_ARRAY[@]}) / ${#LOAD_LIMIT_ARRAY[@]})" | bc)
       if [[ "${LOAD_LIMIT_DYNAMIC:0:1}" == "." ]]; then
	    export LOAD_LIMIT_DYNAMIC="0${LOAD_LIMIT_DYNAMIC}"
       fi
       export RAM_LIMIT_DYNAMIC=$(echo "scale=2; ($(sum_array ${RAM_LIMIT_ARRAY[@]}) / ${#RAM_LIMIT_ARRAY[@]})" | bc)  

       rm -f /tmp/monocloud-health/checks/*
       
       echo "$RAM_LIMIT_DYNAMIC" > /tmp/monocloud-health/checks/last_ram_limit_dynamic
       echo "$LOAD_LIMIT_DYNAMIC" > /tmp/monocloud-health/checks/last_load_limit_dynamic
    fi
    
    [ -z "$RAM_LIMIT_DYNAMIC" ] && export RAM_LIMIT_DYNAMIC=$RAM_LIMIT
    [ -z "$LOAD_LIMIT_DYNAMIC" ] && export LOAD_LIMIT_DYNAMIC=$LOAD_LIMIT

    cd - &>/dev/null
}

#~ check status
check_status() {
    printf "\n"
    echo "Mono Cloud Health Check - $script_version - $(date)"
    printf "\n"

    log_header "Disk Usages"
    info="$(check_partitions | jq -r '.[] | [.percentage, .usage, .total, .partition, .mountpoint, .note] | @tsv')"
    oldIFS=$IFS
    IFS=$'\n'
    for i in ${info[@]}; do
        IFS=$oldIFS a=($i)
        if [[ ${a[0]} -gt $PART_USE_LIMIT ]]; then
            print_colour "Disk Usage is ${a[3]}" "greater than $PART_USE_LIMIT (${a[0]}%)" "error"
        else
            print_colour "Disk Usage is ${a[3]}" "less than $PART_USE_LIMIT (${a[0]}%)"
        fi
    done

    printf "\n"

    log_header "System Load and RAM"
    systemstatus="$(check_system_load_and_ram)"
    
    if [[ -n $(echo $systemstatus | jq -r ". | select(.load | tonumber > ${LOAD_LIMIT_DYNAMIC:-$LOAD_LIMIT})") ]]; then
        print_colour "System Load" "greater than ${LOAD_LIMIT_DYNAMIC:-$LOAD_LIMIT} ($(echo $systemstatus | jq -r '.load'))" "error"
    else
        print_colour "System Load" "less than ${LOAD_LIMIT_DYNAMIC:-$LOAD_LIMIT} ($(echo $systemstatus | jq -r '.load'))"
    fi

    if [[ -n $(echo $systemstatus | jq -r ". | select(.ram | tonumber > ${RAM_LIMIT_DYNAMIC:-$RAM_LIMIT})") ]]; then
        print_colour "RAM Usage" "greater than ${RAM_LIMIT_DYNAMIC:-$RAM_LIMIT} ($(echo $systemstatus | jq -r '.ram'))" "error"
    else
        print_colour "RAM Usage" "less than ${RAM_LIMIT_DYNAMIC:-$RAM_LIMIT} ($(echo $systemstatus | jq -r '.ram'))"
    fi

    printf "\n"

    report_status &>/dev/null
}

freebsd_mib() {
	if [[ "$1" == "vmstat" ]]; then
	    local bytes="$(echo "$(vmstat_jq "$2") * 1024" | bc)"
	else
	    local bytes="$(sysctl -n $1)"
	fi
	local mib=$(echo "($bytes + 524288) / 1048576" | bc)  # Round to the nearest MiB
	echo "$mib"
}

free_custom() {
    
    if command -v free &>/dev/null; then
		free -m "$@"
		return $?
    fi

    # Mem: Total, Used, Free, Shared, Buff/Cache, Available
    total="$(freebsd_mib hw.physmem)" # Correct
    used="$(echo "$total - $(freebsd_mib hw.usermem)" | bc)"

    echo "Mem: $total $used" # Rest we dont need for now
}

#~ check system load and ram
check_system_load_and_ram() {
    [[ -z "$(command -v systemctl)" ]] && is_old=1 || is_old=0
    [[ -z "$(command -v pkg)" ]] && average="average:" || average="averages:" # its 'averages:' instead of 'average:' on freebsd
    load=$(uptime | awk -F"$average" '{print $2}' | awk -F',' '{print $1}' | xargs)
    [[ $is_old == 0 ]] && ram_usage=$(free_custom | awk '/Mem/{printf("%.2f", $3/$2*100)}') || ram_usage=$(free_custom | awk '/Mem/{printf("%.2f", ($3-$6-$7)/$2*100)}')
    local json="{\"load\":\"$load\",\"ram\":\"$ram_usage\"}"

    load_u=$(echo "$load" | awk -F  '.' '{print $1}')
     
    if (( $(echo "$load_u < ${LOAD_LIMIT_DYNAMIC:-$LOAD_LIMIT}" | bc -l) )); then
        message="System load limit went below ${LOAD_LIMIT_DYNAMIC:-$LOAD_LIMIT} (Current: $load)"
        alarm_check_up "load" "$message" "system"
    else
        message="The system load limit has exceeded ${LOAD_LIMIT_DYNAMIC:-$LOAD_LIMIT} (Current: $load)"
        alarm_check_down "load" "$message" "system"
    fi

    ram_u=$(echo "$ram_usage" | awk -F  '.' '{print $1}') 
    
    if [[ "$ram_u" == "$ram_usage" ]]; then
	ram_u=$(echo "$ram_usage" | awk -F  ',' '{print $1}')
    fi
    


    if (( $(echo "$load_u < ${RAM_LIMIT_DYNAMIC:-$RAM_LIMIT}" | bc -l) )); then
        message="RAM usage limit went below ${RAM_LIMIT_DYNAMIC:-$RAM_LIMIT} (Current: $ram_usage%)"
        alarm_check_up "ram" "$message" "system"
    else
        message="RAM usage limit has exceeded ${RAM_LIMIT_DYNAMIC:-$RAM_LIMIT} (Current: $ram_usage%)"
        alarm_check_down "ram" "$message" "system"
    fi

    [ ! -d "/tmp/monocloud-health/checks" ] && mkdir -p /tmp/monocloud-health/checks
    echo $json > /tmp/monocloud-health/checks/$(date +%s).json

    echo $json
}

#~ convert to proper
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

log_header() {
    echo "$1"
    echo "--------------------------------------------------"
}

print_colour() {
    #~ $1: service name  $2: status  $3: type
    if [ "$3" != 'error' ]; then
        printf "  %-40s %s\n" "${color_blue}$1${color_reset}" "is ${color_green}$2${color_reset}"
    else
        printf "  %-40s %s\n" "${color_blue}$1${color_reset}" "is ${color_red}$2${color_reset}"
    fi
}

report_status() {
    local diskstatus="$(check_partitions)"
    local systemstatus="$(check_system_load_and_ram)"
    [[ -n "$SERVER_NICK" ]] && alarm_hostname=$SERVER_NICK || alarm_hostname="$(hostname)"

    local underthreshold_disk=0
    local REDMINE_CLOSE=1
    local REDMINE_SEND_UPDATE=0
    message="{\"text\": \"[Mono Cloud - $alarm_hostname] [✅] Partition usage levels went below ${PART_USE_LIMIT}% for the following partitions;\n\`\`\`\n"
    table="$(printf '%-5s | %-10s | %-10s | %-50s | %s' '%' 'Used' 'Total' 'Partition' 'Mount Point')"
    table+='\n'
    for z in $(seq 1 110); do table+="$(printf '-')"; done
    if [[ -n "$(echo $diskstatus | jq -r ".[] | select(.percentage | tonumber < $PART_USE_LIMIT)")" ]]; then
        local oldifs=$IFS
        IFS=$'\n'
        for info in $(echo $diskstatus | jq -r ".[] | select(.percentage | tonumber < $PART_USE_LIMIT) | [.percentage, .usage, .total, .partition, .mountpoint] | @tsv"); do
            IFS=$oldifs a=($info)
            percentage=${a[0]}
            usage=${a[1]}
            total=${a[2]}
            partition=${a[3]}
            mountpoint=${a[4]}

            [[ "$mountpoint" == "/" ]] && mountpoint="/sys_root"
            [[ -f "/tmp/monocloud-health/${mountpoint//\//_}" ]] && {
                table+="\n$(printf '%-5s | %-10s | %-10s | %-50s | %-35s' $percentage% $usage $total $partition ${mountpoint//sys_root/})"
                underthreshold_disk=1
                rm -f /tmp/monocloud-health/${mountpoint//\//_}
            }
	    if [[ -f "/tmp/monocloud-health/redmine_issue_id" && $percentage -ge $((PART_USE_LIMIT - ${REDMINE_ISSUE_DELETE_THRESHOLD:-5})) ]]; then
		REDMINE_CLOSE=0
	    fi
        done
        message+="$table\n\`\`\`\"}"
        IFS=$oldifs
        #[[ "$underthreshold_disk" == "1" ]] && echo $message || { echo "There's no alarm for Underthreshold today..."; }
        if [[ "$underthreshold_disk" == "1" ]]; then
	    curl -fsSL -X POST -H "Content-Type: application/json" -d "$message" "$WEBHOOK_URL" || { echo "There's no alarm for Underthreshold (DISK) today."; }
	    if [[ "${REDMINE_ENABLE:-1}" == "1" && -f "/tmp/monocloud-health/redmine_issue_id" && "$REDMINE_CLOSE" == "1" ]]; then
		# Delete issue
		#curl -fsSL -X DELETE -H "Content-Type: application/json" -H "X-Redmine-API-Key: $REDMINE_API_KEY" "$REDMINE_URL"/issues/$(cat /tmp/monocloud-health/redmine_issue_id).json
		curl -fsSL -X PUT -H "Content-Type: application/json" -H "X-Redmine-API-Key: $REDMINE_API_KEY" -d "{\"issue\": { \"id\": $(cat /tmp/monocloud-health/redmine_issue_id), \"notes\": \"Threshold %$percentage altına geri indi, iş kapatıldı\", \"status_id\": \"${REDMINE_STATUS_ID_CLOSED:-5}\" }}" "$REDMINE_URL"/issues/$(cat /tmp/monocloud-health/redmine_issue_id).json
		rm -f /tmp/monocloud-health/redmine_issue_id
	    fi
	fi
    fi

    local overthreshold_disk=0
    message="{\"text\": \"[Mono Cloud - $alarm_hostname] [🔴] Partition usage level has exceeded ${PART_USE_LIMIT}% for the following partitions;\n\`\`\`\n"
    table="$(printf '%-5s | %-10s | %-10s | %-50s | %s' '%' 'Used' 'Total' 'Partition' 'Mount Point')\n"
    for z in $(seq 1 110); do table+="$(printf '-')"; done
    if [[ -n "$(echo $diskstatus | jq -r ".[] | select(.percentage | tonumber > $PART_USE_LIMIT)")" ]]; then
        local oldifs=$IFS
        IFS=$'\n'
        for info in $(echo $diskstatus | jq -r ".[] | select(.percentage | tonumber > $PART_USE_LIMIT) | [.percentage, .usage, .total, .partition, .mountpoint] | @tsv"); do
            IFS=$oldifs a=($info)
            percentage=${a[0]}
            usage=${a[1]}
            total=${a[2]}
            partition=${a[3]}
            mountpoint=${a[4]}

	    if [[ -f "/tmp/monocloud-health/${mountpoint//\//_}-redmine" && "$(cat /tmp/monocloud-health/${mountpoint//\//_}-redmine)" != "$percentage" ]]; then
		REDMINE_SEND_UPDATE=1
	    fi

	    echo "$percentage" > /tmp/monocloud-health/${mountpoint//\//_}-redmine

            [[ "$mountpoint" == "/" ]] && mountpoint="/sys_root"
            if [[ -f "/tmp/monocloud-health/${mountpoint//\//_}" ]]; then
                if [[ "$(cat /tmp/monocloud-health/${mountpoint//\//_})" == "$(date +%Y-%m-%d)" ]]; then
                    overthreshold_disk=0
                    continue
                else
                    date +%Y-%m-%d >/tmp/monocloud-health/${mountpoint//\//_}
                    overthreshold_disk=1
                fi
            else
                date +%Y-%m-%d >/tmp/monocloud-health/${mountpoint//\//_}
                overthreshold_disk=1
            fi



            table+="\n$(printf '%-5s | %-10s | %-10s | %-50s | %-35s' $percentage% $usage $total $partition ${mountpoint//sys_root/})"
        done
        message+="$table\n\`\`\`\"}"
        IFS=$oldifs
        if [[ "$overthreshold_disk" == "1" ]]; then
	    curl -fsSL -X POST -H "Content-Type: application/json" -d "$message" "$WEBHOOK_URL"
	    
	    if [ "${REDMINE_ENABLE:-1}" == "1" ]; then
		if [[ ! -f "/tmp/monocloud-health/redmine_issue_id" ]]; then

		    curl -fsSL -X POST -H "Content-Type: application/json" -H "X-Redmine-API-Key: $REDMINE_API_KEY" -d "{\"issue\": { \"project_id\": \"$(echo $SERVER_NICK | cut -d '-' -f 1)\", \"tracker_id\": \"${REDMINE_TRACKER_ID:-7}\", \"subject\": \"$alarm_hostname - Diskteki bir (ya da birden fazla) bölümün doluluk seviyesi %${PART_USE_LIMIT} seviyesinin üstüne çıktı\", \"description\": \"\`\`\`\n$table\n\`\`\`\", \"status_id\": \"${REDMINE_STATUS_ID:-open}\", \"priority_id\": \"${REDMINE_PRIORITY_ID:-5}\" }}" "$REDMINE_URL"/issues.json -o /tmp/monocloud-health/redmine.json
		    echo "$"
		    jq -r '.issue.id' /tmp/monocloud-health/redmine.json > /tmp/monocloud-health/redmine_issue_id
		    rm -f /tmp/monocloud-health/redmine.json
		elif [[ "$REDMINE_SEND_UPDATE" == "1" ]]; then
		    curl -fsSL -X PUT -H "Content-Type: application/json" -H "X-Redmine-API-Key: $REDMINE_API_KEY" -d "{\"issue\": { \"id\": $(cat /tmp/monocloud-health/redmine_issue_id), \"notes\": \"\`\`\`\n$table\n\`\`\`\" }}" "$REDMINE_URL"/issues/$(cat /tmp/monocloud-health/redmine_issue_id).json
		fi
	    fi
	else
	    echo "There's no alarm for Overthreshold (DISK) today..."
	fi
    fi
}

#~ usage
usage() {
    echo -e "Usage: $0 [-c <configfile>] [-h] [-l] [-V] [-v]"
    echo -e "\t-c | --config   <configfile> : Use custom config file. (default: $CONFIG_PATH)"
    echo -e "\t-l | --list                  : List partition status."
    echo -e "\t-V | --validate              : Validate temporary directory and config."
    echo -e "\t-v | --version               : Print script version."
    echo -e "\t-h | --help                  : Print this message."
}

#~ validate
validate() {
    required_apps=("bc" "curl" "jq")
    missing_apps=""
    for a in ${required_apps[@]}; do
        [[ ! -e "$(command -v $a)" ]] && missing_apps+="$a, "
    done
    [[ -n "$missing_apps" ]] && { echo -e "${c_red}[ FAIL ] Please install this apps before proceeding: (${missing_apps%, })"; } || { echo -e "${c_green}[  OK  ] Required apps are already installed."; }
    curl -fsSL $(echo $WEBHOOK_URL | grep_custom -o '(?<=\:\/\/)(([a-z]|\.)+)') &>/dev/null
    [[ ! "$?" -eq "0" ]] && { echo -e "${c_red}[ FAIL ] Webhook URL is not reachable."; } || { echo -e "${c_green}[  OK  ] Webhook URL is reachable."; }
    touch /tmp/monocloud-health/.testing
    [[ ! "$?" -eq "0" ]] && { echo -e "${c_red}[ FAIL ] /tmp/monocloud-health is not writable."; } || { echo -e "${c_green}[  OK  ] /tmp/monocloud-health is writable."; }
}

#~ main
main() {
    mkdir -p /tmp/monocloud-health
    
    CONFIG_PATH="/etc/monocloud-health.conf"
    
    if [ "$1" == "--debug" ] || [ "$1" == "-d" ]; then
		set -x
		shift
    fi

    if [[ "$1" == "--config="* ]] || [[ "$1" == "-c="* ]]; then
	local config_path_tmp="${1#*=}"
	local config_path_tmp="${config_path_tmp:-false}"
	shift
    elif [[ ( "$1" == "--config" || "$1" == "-c" ) && ! "$2" =~ ^- ]]; then	
	local config_path_tmp="${2:-false}"
	shift 2
    fi

    if [[ "$config_path_tmp" == "false" ]]; then
	echo "$0: option requires an argument -- 'config/-c'"
	shift
    elif [[ -n "$config_path_tmp" ]]; then
	CONFIG_PATH="$config_path_tmp"
    fi
    
    check_config_file "$CONFIG_PATH" && . "$CONFIG_PATH"
    
    [[ -z "$ALARM_INTERVAL" ]] && ALARM_INTERVAL=3
    [[ -z "$DYNAMIC_LIMIT_INTERVAL" ]] && DYNAMIC_LIMIT_INTERVAL=100

    dynamic_limit

    [[ $# -eq 0 ]] && {
	check_status
	exit 1
    }

    while [[ $# -gt 0 ]]; do
	case $1 in
	    -l | --list)
		check_partitions | jq
	    ;;  
	    -V | --validate)
		validate
            ;;
	    -v | --version)
		echo "Script Version: $script_version"
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
