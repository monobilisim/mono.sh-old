#!/bin/bash
###~ description: This script is used to check the health of the server
#~ variables
script_version="v3.0.0"

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

#~ check configuration file
check_config_file() {
    [[ ! -f "$@" ]] && {
        echo "File \"$@\" does not exists, exiting..."
        exit 1
    }
    . "$@"
    local required_vars=(FILESYSTEMS PART_USE_LIMIT LOAD_LIMIT RAM_LIMIT WEBHOOK_URL)
    for var in "${required_vars[@]}"; do
        [[ -z "${!var}" ]] && {
            echo "Variable \"$var\" is not set in \"$@\". exiting..."
            exit 1
        }
    done
    return 0
}

if [ -z "$ALARM_INTERVAL" ]; then
    ALARM_INTERVAL=3
fi

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

        old=$(date -d "$(awk '{print $1, $2}' <"${file_path}")" +%s)
        new=$(date -d "$(date '+%Y-%m-%d %H:%M')" +%s)

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
                alarm "Monocloud - $alarm_hostname] [:red_circle:] $2"
            fi
        else
            date "+%Y-%m-%d %H:%M" >"${file_path}"
            alarm "Monocloud - $alarm_hostname] [:red_circle:] $2"
        fi
    else
        if [ -f "${file_path}" ]; then
            old_date=$(awk '{print $1}' <"$file_path")
            [[ -z $(awk '{print $3}' <"$file_path") ]] && locked=false || locked=true
            current_date=$(date "+%Y-%m-%d")
            if [ "${old_date}" != "${current_date}" ]; then
                date "+%Y-%m-%d %H:%M locked" >"${file_path}"
                alarm "Monocloud - $alarm_hostname] [:red_circle:] $2"
            else
                if ! $locked; then
                    time_diff=$(get_time_diff "$1")
                    if ((time_diff >= ALARM_INTERVAL)); then
                        date "+%Y-%m-%d %H:%M locked" >"${file_path}"
                        alarm "Monocloud - $alarm_hostname] [:red_circle:] $2"
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
            alarm "Monocloud - $alarm_hostname] [:check:] $2"
        else
            [[ -z $(awk '{print $3}' <"$file_path") ]] && locked=false || locked=true
            rm -rf "${file_path}"
            if $locked; then
                alarm "Monocloud - $alarm_hostname] [:check:] $2"
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
    local partitions="$(df -l --output='source,fstype,target' | sed '1d' | sort | uniq | grep -E $(echo ${FILESYSTEMS[@]} | sed 's/ /|/g') | awk '$2 != "zfs" {print} $2 == "zfs" && $1 !~ /\//')"
    oldIFS=$IFS
    local json="["
    IFS=$'\n'
    for partition in $partitions; do
        IFS=$oldIFS info=($partition)
        local partition="${info[0]}"
        local filesystem="${info[1]}"
        local mountpoint="${info[2]}"
        if [[ "${FILESYSTEMS[@]}" =~ "$filesystem" ]]; then
            if [[ "$filesystem" == "fuse.zfs" ]]; then
                note="Fuse ZFS is not supported yet."
                usage="0"
                avail="0"
                total="0"
                percentage="0"
            elif [[ "$filesystem" == "zfs" ]]; then
                usage=$(zfs list -H -p -o used "$partition")
                avail=$(zfs list -H -p -o avail "$partition")
                total=$((usage + avail))
                percentage=$((usage * 100 / total))
            elif [[ "$filesystem" == "btrfs" ]]; then
                usage=$(btrfs fi us -b $mountpoint | grep -P '^\s.+Used' | awk '{print $2}')
                total=$(btrfs fi us -b $mountpoint | grep -P 'Device size' | awk '{print $3}')
                percentage=$(echo "scale=2; $usage / $total * 100" | bc)
            else
                stat=($(df -B1 --output="used,size,pcent" $mountpoint | sed '1d'))
                usage=${stat[0]}
                total=${stat[1]}
                percentage=${stat[2]}
            fi
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

#~ check status
check_status() {
    printf "\n"
    echo "Monocloud Health Check - $script_version - $(date)"
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
    if [[ -n $(echo $systemstatus | jq -r ". | select(.load | tonumber > $LOAD_LIMIT)") ]]; then
        print_colour "System Load" "greater than $LOAD_LIMIT ($(echo $systemstatus | jq -r '.load'))" "error"
    else
        print_colour "System Load" "less than $LOAD_LIMIT ($(echo $systemstatus | jq -r '.load'))"
    fi

    if [[ -n $(echo $systemstatus | jq -r ". | select(.ram | tonumber > $RAM_LIMIT)") ]]; then
        print_colour "RAM Usage" "greater than $RAM_LIMIT ($(echo $systemstatus | jq -r '.ram'))" "error"
    else
        print_colour "RAM Usage" "less than $RAM_LIMIT ($(echo $systemstatus | jq -r '.ram'))"
    fi

    printf "\n"

    report_status &>/dev/null
}

#~ check system load and ram
check_system_load_and_ram() {
    [[ -z "$(command -v systemctl)" ]] && is_old=1 || is_old=0
    load=$(uptime | awk -F'average:' '{print $2}' | awk -F',' '{print $1}' | xargs)
    [[ $is_old == 0 ]] && ram_usage=$(free -m | awk '/Mem/{printf("%.2f", $3/$2*100)}') || ram_usage=$(free -m | awk '/Mem/{printf("%.2f", ($3-$6-$7)/$2*100)}')
    local json="{\"load\":\"$load\",\"ram\":\"$ram_usage\"}"
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
    message="{\"text\": \"[Monocloud - $alarm_hostname] [✅] Partition usage levels went below ${PART_USE_LIMIT}% for the following partitions;\n\`\`\`\n"
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
        done
        message+="$table\n\`\`\`\"}"
        IFS=$oldifs
        #[[ "$underthreshold_disk" == "1" ]] && echo $message || { echo "There's no alarm for Underthreshold today..."; }
        [[ "$underthreshold_disk" == "1" ]] && curl -fsSL -X POST -H "Content-Type: application/json" -d "$message" "$WEBHOOK_URL" || { echo "There's no alarm for Underthreshold (DISK) today."; }
    fi

    local overthreshold_disk=0
    message="{\"text\": \"[Monocloud - $alarm_hostname] [🔴] Partition usage level has exceeded ${PART_USE_LIMIT}% for the following partitions;\n\`\`\`\n"
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
        #[[ "$overthreshold_disk" == "1" ]] && echo $message || { echo "There's no alarm for Overthreshold today."; }
        [[ "$overthreshold_disk" == "1" ]] && curl -fsSL -X POST -H "Content-Type: application/json" -d "$message" "$WEBHOOK_URL" || { echo "There's no alarm for Overthreshold (DISK) today..."; }
    fi

    if [[ -n $(echo "$systemstatus" | jq -r ". | select(.load | tonumber < $LOAD_LIMIT)") ]]; then
        message="System load limit went below $LOAD_LIMIT Current: $(echo "$systemstatus" | jq -r '.load')%)"
        alarm_check_up "load" "$message" "system"
    else
        message="The system load limit has exceeded $LOAD_LIMIT Current: $(echo "$systemstatus" | jq -r '.load')%)"
        alarm_check_down "load" "$message" "system"
    fi

    if [[ -n $(echo "$systemstatus" | jq -r ". | select(.ram | tonumber < $RAM_LIMIT)") ]]; then
        message="RAM usage limit went below $RAM_LIMIT (Current: $(echo "$systemstatus" | jq -r '.ram')%)"
        alarm_check_up "ram" "$message" "system"
    else
        message="RAM usage limit has exceeded $RAM_LIMIT (Current: $(echo "$systemstatus" | jq -r '.ram')%)"
        alarm_check_down "ram" "$message" "system"
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
    curl -fsSL $(echo $WEBHOOK_URL | grep -Po '(?<=\:\/\/)(([a-z]|\.)+)') &>/dev/null
    [[ ! "$?" -eq "0" ]] && { echo -e "${c_red}[ FAIL ] Webhook URL is not reachable."; } || { echo -e "${c_green}[  OK  ] Webhook URL is reachable."; }
    touch /tmp/monocloud-health/.testing
    [[ ! "$?" -eq "0" ]] && { echo -e "${c_red}[ FAIL ] /tmp/monocloud-health is not writable."; } || { echo -e "${c_green}[  OK  ] /tmp/monocloud-health is writable."; }
}

#~ main
main() {
    mkdir -p /tmp/monocloud-health
    opt=($(getopt -l "config:,debug,list,validate,version,help" -o "c:,d,l,V,v,h" -n "$0" -- "$@"))
    eval set -- "${opt[@]}"
    CONFIG_PATH="/etc/monocloud-health.conf"
    [[ "$1" == '-c' ]] || [[ "$1" == '--config' ]] && { [[ -n $2 ]] && CONFIG_PATH=$2; }
    [[ "$1" == '-d' ]] || [[ "$1" == '--debug' ]] && { set +x; }
    check_config_file "$CONFIG_PATH" && . "$CONFIG_PATH"

    [[ "${#opt[@]}" == "1" ]] && {
        check_status
        exit 1
    }

    while true; do
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
