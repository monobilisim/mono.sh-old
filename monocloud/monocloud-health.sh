#!/bin/bash
###~ descrtiption: This script is used to check the health of the server
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
    echo "Disk durumları kontrol ediliyor..."
    diskout="$(check_partitions)"
    if [[ -n "$diskout" && $(echo $diskout | jq -r ".[] | select(.percentage | tonumber > $PART_USE_LIMIT)") ]]; then
        echo -e "${c_red}[ WARN ] Disk kullanımı limitini aşan bölüm bulundu. Alarm gönderilecek...${c_reset}"
    else
        echo -e "${c_green}[  OK  ] Disk kullanımı limitini aşan bölüm yok.${c_reset}"
    fi
    printf "\n"

    echo "Sistem yükü ve RAM kullanımı kontrol ediliyor..."
    systemout="$(check_system_load_and_ram)"

    if [[ -n "$systemout" && $(echo $systemout | jq -r ". | select(.load | tonumber > $LOAD_LIMIT)") ]]; then
        echo -e "${c_red}[ WARN ] Sistem yükü limiti aşıldı. Alarm gönderiliyor...${c_reset}"
    else
        echo -e "${c_green}[  OK  ] Sistem yükü limiti aşılmadı."
    fi

    if [[ -n "$systemout" && $(echo $systemout | jq -r ". | select(.ram | tonumber > $RAM_LIMIT)") ]]; then
        echo -e "${c_red}[ WARN ] RAM kullanımı limiti aşıldı. Alarm gönderiliyor...${c_reset}"
    else
        echo -e "${c_green}[  OK  ] RAM kullanımı limiti aşılmadı.${c_reset}"
    fi
    printf "\n"

    report_status
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

report_status() {
    local diskstatus="$(check_partitions)"
    local systemstatus="$(check_system_load_and_ram)"
    [[ -n "$SERVER_NICK" ]] && alarm_hostname=$SERVER_NICK || alarm_hostname="$(hostname)"

    local underthreshold_disk=0
    message="{\"text\": \"[Monocloud - $alarm_hostname] [✅] Bölüm kullanım seviyesi aşağıdaki bölümler için %$PART_USE_LIMIT seviyesinin altına indi;\n\`\`\`\n"
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
        #[[ "$underthreshold_disk" == "1" ]] && echo $message || { echo "Underthreshold için bugün gönderilecek alarm yok..."; }
        [[ "$underthreshold_disk" == "1" ]] && curl -fsSL -X POST -H "Content-Type: application/json" -d "$message" "$WEBHOOK_URL" || { echo "Underthreshold (DISK) için bugün gönderilecek alarm yok..."; }
    fi


    local overthreshold_disk=0
    message="{\"text\": \"[Monocloud - $alarm_hostname] [🔴] Bölüm kullanım seviyesi aşağıdaki bölümler için %$PART_USE_LIMIT seviyesinin üstüne çıktı;\n\`\`\`\n"
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
        #[[ "$overthreshold_disk" == "1" ]] && echo $message || { echo "Overthreshold için bugün gönderilecek alarm yok..."; }
        [[ "$overthreshold_disk" == "1" ]] && curl -fsSL -X POST -H "Content-Type: application/json" -d "$message" "$WEBHOOK_URL" || { echo "Overthreshold (DISK) için bugün gönderilecek alarm yok..."; }
    fi

    local underthreshold_system=0
    message="{\"text\": \"[Monocloud - $alarm_hostname] [✅] Sistem yükü limiti $LOAD_LIMIT seviyesinin altına indi...\"}"
    if [[ -n $(echo $systemstatus | jq -r ". | select(.load | tonumber < $LOAD_LIMIT)") ]]; then
        if [[ -f "/tmp/monocloud-health/system_load" ]]; then
            underthreshold_system=1
            rm -f /tmp/monocloud-health/system_load
            curl -fsSL -X POST -H "Content-Type: application/json" -d "$message" "$WEBHOOK_URL"
        else
            echo "Underthreshold (SYS) için bugün gönderilecek alarm yok..."
        fi
    fi

    local overthreshold_system=0
    message="{\"text\": \"[Monocloud - $alarm_hostname] [🔴] Sistem yükü limiti $LOAD_LIMIT seviyesinin üstüne çıktı...\"}"
    if [[ -n $(echo $systemstatus | jq -r ". | select(.load | tonumber > $LOAD_LIMIT)") ]]; then
        if [[ -f "/tmp/monocloud-health/system_load" && "$(cat /tmp/monocloud-health/system_load)" == "$(date +%Y-%m-%d)" ]]; then
            echo "Overthreshold (SYS) için bugün gönderilecek alarm yok..."
        else
            overthreshold_system=1
            date +%Y-%m-%d >/tmp/monocloud-health/system_load
            curl -fsSL -X POST -H "Content-Type: application/json" -d "$message" "$WEBHOOK_URL"
        fi
    fi

    local underthreshold_ram=0
    message="{\"text\": \"[Monocloud - $alarm_hostname] [✅] RAM kullanımı limiti $RAM_LIMIT seviyesinin altına indi...\"}"
    if [[ -n $(echo $systemstatus | jq -r ". | select(.ram | tonumber < $RAM_LIMIT)") ]]; then
        if [[ -f "/tmp/monocloud-health/ram_usage" ]]; then
            underthreshold_ram=1
            rm -f /tmp/monocloud-health/ram_usage
            curl -fsSL -X POST -H "Content-Type: application/json" -d "$message" "$WEBHOOK_URL"
        else
            echo "Underthreshold (RAM) için bugün gönderilecek alarm yok..."
        fi
    fi

    local overthreshold_ram=0
    message="{\"text\": \"[Monocloud - $alarm_hostname] [🔴] RAM kullanımı limiti $RAM_LIMIT seviyesinin üstüne çıktı...\"}"
    if [[ -n $(echo $systemstatus | jq -r ". | select(.ram | tonumber > $RAM_LIMIT)") ]]; then
        if [[ -f "/tmp/monocloud-health/ram_usage" && "$(cat /tmp/monocloud-health/ram_usage)" == "$(date +%Y-%m-%d)" ]]; then
            echo "Overthreshold (RAM) için bugün gönderilecek alarm yok..."
        else
            overthreshold_ram=1
            date +%Y-%m-%d >/tmp/monocloud-health/ram_usage
            curl -fsSL -X POST -H "Content-Type: application/json" -d "$message" "$WEBHOOK_URL"
        fi
    fi

}

#~ usage
usage() {
    echo -e "Usage: $0 [-c <configfile>] [-C] [-h] [-l] [-V] [-v]"
    echo -e "\t-c | --config   <configfile> : Use custom config file. (default: $CONFIG_PATH)"
    echo -e "\t-C | --check                 : Check system load, ram and disk."
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
    opt=($(getopt -l "config:,check,debug,list,validate,version,help" -o "c:,C,d,l,V,v,h" -n "$0" -- "$@"))
    eval set -- "${opt[@]}"
    CONFIG_PATH="/etc/monocloud-health.conf"
    [[ "$1" == '-c' ]] || [[ "$1" == '--config' ]] && { [[ -n $2 ]] && CONFIG_PATH=$2; }
    [[ "$1" == '-d' ]] || [[ "$1" == '--debug' ]] && { set +x; }
    check_config_file "$CONFIG_PATH" && . "$CONFIG_PATH"
    # [[ "${#opt[@]}" == "1" ]] && { check_partitions; exit 1; }
    while true; do
        case $1 in
        -C | --check)
            check_status
            ;;
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
