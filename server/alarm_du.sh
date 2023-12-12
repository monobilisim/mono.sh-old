#!/bin/bash
###~ description: When disk fullness reaches a certain limit, it sends a notification to the specified url.
####################################
#
## DU (Disk Usage) Alarm for Zulip
#
####################################
#~ set path
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

#~ check applications
checkapps() {
    for a in ${required_packages[@]}; do
        [[ ! -e $(command -v $a) ]] && {
            echo "Scripti çalıştırmadan önce \"$a\" programını yükleyin..."
            exit 1
        }
    done
}

#~ check config
checkconfig() {
    if [[ ! -e /etc/alarm_du.conf ]]; then
        echo "/etc/alarm_du.conf dosyasi github'tan cekiliyor..."
        curl -fsSL https://raw.githubusercontent.com/monobilisim/mono.sh/main/.bin/alarm_du_v2.conf | sudo tee /etc/alarm_du.conf
        echo "/etc/alarm_du.conf dosyasını düzenleyin ve scripti tekrar çalıştırın"
        exit 0
    else
        . /etc/alarm_du.conf
    fi
}

#~ check variables
checkvariable() {
    local arr=($@)
    for a in ${arr[@]}; do
        [[ ! -n ${!a} ]] && {
            echo "\"${a^}\" değişkeni /etc/alarm_du.conf dosyası içinde tanımlı değil"
            exit 1
        }
    done
}

#~ convert to bytes
convertToBytes() {
    local value="$@"
    local unit="$(echo $value | sed 's/ //g' | tr -d [:digit:] | tr -d '.')"
    case "$unit" in
    "KiB")
        printf "%.f" "$(echo "${value%"$unit"} * 1024" | bc)"
        ;;
    "MiB")
        printf "%.f" "$(echo "${value%"$unit"} * 1024^2" | bc)"
        ;;
    "GiB")
        printf "%.f" "$(echo "${value%"$unit"} * 1024^3" | bc)"
        ;;
    "TiB")
        printf "%.f" "$(echo "${value%"$unit"} * 1024^4" | bc)"
        ;;
    "KB"|"K")
        printf "%.f" "$(echo "${value%"$unit"} * 1000" | bc)"
        ;;
    "MB"|"M")
        printf "%.f" "$(echo "${value%"$unit"} * 1000^2" | bc)"
        ;;
    "GB"|"G")
        printf "%.f" "$(echo "${value%"$unit"} * 1000^3" | bc)"
        ;;
    "TB"|"T")
        printf "%.f" "$(echo "${value%"$unit"} * 1000^4" | bc)"
        ;;
    *)
        printf "%.f" "${value//%/}"
        ;;
    esac
}

convertToProper() {
    value=$1
    dummy=$value
    for i in {0..7}; do
        if [[ ${dummy:0:1} == 0 ]]; then
            dummy=$((dummy * 1024))
            case $i in
            1)
                echo "$(echo "scale=1; $value / 1024^($i-1)" | bc)"B
                ;;
            2)
                echo "$(echo "scale=1; $value / 1024^($i-1)" | bc)"KiB
                ;;
            3)
                echo "$(echo "scale=1; $value / 1024^($i-1)" | bc)"MiB
                ;;
            4)
                echo "$(echo "scale=1; $value / 1024^($i-1)" | bc)"GiB
                ;;
            5)
                echo "$(echo "scale=1; $value / 1024^($i-1)" | bc)"TiB
                ;;
            6)
                echo "$(echo "scale=1; $value / 1024^($i-1)" | bc)"PiB
                ;;
            esac
            break
        else
            dummy=$((dummy / 1024))
        fi
    done
}

#~ convert to json to df output
json="["
getPartitionInformations() {
    local arr=($@)
    local diskout="$(df --output='source,fstype,target' | sed '1d' | sort | uniq | grep -E $(echo ${arr[@]} | sed 's/ /|/g') | awk '$2 != "zfs" {print} $2 == "zfs" && $1 !~ /\//')"
    OLDIFS=$IFS
    IFS=$'\n'
    for a in ${diskout[@]}; do
        local partition=$(echo $a | awk '{print $1}')
        local fs=$(echo $a | awk '{print $2}')
        local mount=$(echo $a | awk '{print $3}')
        if [[ -n $(echo "$a" | awk '{print $2}' | grep -E 'ext4|ext3|ext2|xfs|nfs4') ]]; then
            local usage=$(df -B 1 --output="used" "$mount" | sed '1d; s/%//g' | tr -d ' ')
            local total=$(df -B 1 --output="size" "$mount" | sed '1d; s/%//g' | tr -d ' ')
            local percentage=$(df --output="pcent" "$mount" | sed '1d; s/%//g' | tr -d ' ')
        elif [[ $(echo "$a" | awk '{print $2}') == "btrfs" ]]; then
            local usage=$(btrfs fi us -b "$mount" 2>/dev/null | grep "^    Used:" | awk '{print $2}')
            local total=$(btrfs fi us -b "$mount" 2>/dev/null | grep "Device size:" | awk '{print $3}')
            local percentage=$(echo "scale=2; $usage" / $total * 100 | bc)
        elif [[ $(echo "$a" | awk '{print $2}') == "zfs" ]]; then
            local usage=$(zfs list -H -p -o used "$partition")
            local avail=$(zfs list -H -p -o avail "$partition")
            local total=$((usage + avail))
            local percentage=$((usage * 100 / total))
        fi
        usage=$(convertToProper $usage)
        total=$(convertToProper $total)
        json+="{\"partition\":\"$partition\",\"fs\":\"$fs\",\"mount\":\"$mount\",\"percentage\":\"$percentage\",\"usage\":\"$usage\",\"total\":\"$total\"},"
    done
    json=${json/%,/}
    json+="]"
    IFS=$OLDIFS
}

#~ check parts
checkAndReportPartitions() {
    local underthreshold=0
    local message="{\"text\": \"[ÇÖZÜLDÜ] - [ $(hostname) ] Bölüm kullanım seviyesi aşağıdaki bölümler için $threshold% seviyesinin altına indi;\n\`\`\`\n"
    local table="$(printf '%-5s | %-10s | %-10s | %-35s | %s' '%' 'Used' 'Total' 'Partition' 'Mount Point')"
    table+='\n'
    for z in $(seq 1 95); do table+="$(printf '-')"; done
    OLDIFS=$IFS
    IFS=$'\n'
    for a in $(echo $json | jq -r ".[] | select(.percentage | tonumber < $threshold) | [.percentage, .usage, .total, .partition, .mount] | @tsv"); do
        local percentage=$(echo $a | awk -F'\t' '{print $1}')
        local usage=$(echo $a | awk -F'\t' '{print $2}')
        local total=$(echo $a | awk -F'\t' '{print $3}')
        local partition=$(echo $a | awk -F'\t' '{print $4}')
        local mount=$(echo $a | awk -F'\t' '{print $5}')
        [[ "$mount" == "/" ]] && mount="/sys_root"
        [[ -f "/tmp/alarm_du/${mount//\//_}" ]] && {
            table+="\n$(printf '%-5s | %-10s | %-10s | %-35s | %-35s' $percentage% $usage $total $partition ${mount//sys_root/})"
            underthreshold=1
            rm -f /tmp/alarm_du/${mount//\//_}
        }
    done
    message+="$table\n\`\`\`\"}"
    IFS=$OLDIFS
    # [[ "$underthreshold" == "1" ]] && echo $message
    [[ "$underthreshold" == "1" ]] && curl -X POST -H "Content-Type: application/json" -d "$message" "$webhook_url" || { echo "Underthreshold için bugün gönderilecek alarm yok..."; }

    local overthreshold=0
    local jsondata=$(echo $json | jq -r ".[] | select(.percentage | tonumber >= ${threshold//%/}) | [.percentage, .usage, .total, .partition, .mount] | @tsv")
    if [[ -n $jsondata ]]; then
        local message="{\"text\": \"[UYARI] - [ $(hostname) ] Bölüm kullanım seviyesi aşağıdaki bölümler için $threshold% seviyesinin üstüne çıktı;\n\`\`\`\n"
        local table="$(printf '%-5s | %-10s | %-10s | %-35s | %s' '%' 'Used' 'Total' 'Partition' 'Mount Point')"
        table+='\n'
        for z in $(seq 1 95); do table+="$(printf '-')"; done
        OLDIFS=$IFS
        IFS=$'\n'
        for b in ${jsondata[@]}; do
            local percentage=$(echo $b | awk -F'\t' '{print $1}')
            local usage=$(echo $b | awk -F'\t' '{print $2}')
            local total=$(echo $b | awk -F'\t' '{print $3}')
            local partition=$(echo $b | awk -F'\t' '{print $4}')
            local mount=$(echo $b | awk -F'\t' '{print $5}')
            [[ "$mount" == "/" ]] && mount="/sys_root"
            [[ -f "/tmp/alarm_du/${mount//\//_}" ]] && { [[ "$(cat /tmp/alarm_du/${mount//\//_})" == "$(date +%Y-%m-%d)" ]] && {
                overthreshold=0
                continue
            }; } || {
                date +%Y-%m-%d >/tmp/alarm_du/${mount//\//_}
                overthreshold=1
            }
            table+="\n$(printf '%-5s | %-10s | %-10s | %-35s | %-35s' $percentage% $usage $total $partition ${mount//sys_root/})"
        done
        IFS=$OLDIFS
    fi
    message+="$table\n\`\`\`\"}"
    # [[ "$overthreshold" == "1" ]] && echo $message
    [[ "$overthreshold" == "1" ]] && curl -X POST -H "Content-Type: application/json" -d "$message" "$webhook_url" || { echo "Overthreshold için bugün gönderilecek alarm yok..."; }
}

#~ processes
mkdir -p /tmp/alarm_du
checkconfig
checkapps
checkvariable webhook_url threshold filesystems
getPartitionInformations "${filesystems[@]}"
[[ "$1" == "--list" ]] || [[ "$1" == "-l" ]] && {
    echo "$json" | jq
    exit
}
checkAndReportPartitions
