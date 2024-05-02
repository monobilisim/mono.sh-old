#!/bin/bash
###~ description: Checks the status of monofon and related services

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
mkdir -p /tmp/monofon-health

VERSION=v1.1.0

if [[ -f /etc/monofon-health.conf ]]; then
    . /etc/monofon-health.conf
else
    echo "Config file doesn't exists at /etc/monofon-health.conf"
    exit 1
fi
if [ -z "$TRUNK_CHECK_INTERVAL" ]; then
    TRUNK_CHECK_INTERVAL=5
fi

RED_FG=$(tput setaf 1)
GREEN_FG=$(tput setaf 2)
BLUE_FG=$(tput setaf 4)
RESET=$(tput sgr0)

SERVICES=("asterniclog" "fop2" "freepbx" "httpd" "mariadb")

function echo_status() {
    echo "$1"
    echo ---------------------------------------------------
}

function print_colour() {
    if [ "$3" != 'error' ]; then
        printf "  %-40s %s\n" "${BLUE_FG}$1${RESET}" "is ${GREEN_FG}$2${RESET}"
    else
        printf "  %-40s %s\n" "${BLUE_FG}$1${RESET}" "is ${RED_FG}$2${RESET}"
    fi
}

containsElement() {
    local e match="$1"
    shift
    for e; do [[ "$e" == "$match" ]] && return 0; done
    return 1
}

function check_service() {
    if [ "$is_old" == "0" ]; then
        if systemctl status "$1" >/dev/null; then
            alarm_check_up "$1" "Service $1 started running again at $IDENTIFIER"
            print_colour "$1" "running"
        else
            print_colour "$1" "not running" "error"
            alarm_check_down "$1" "Service $1 is not running at $IDENTIFIER"
            if [ "$AUTO_RESTART" == "1" ]; then
                if [[ "$1" == "freepbx" || "$1" == "asterisk" ]]; then
                    restart_asterisk
                else
                    time_diff=$(get_time_diff "$1")
                    if ((time_diff >= RESTART_ATTEMPT_INTERVAL)) || ((time_diff == 0)); then
                        print_colour "$1" "not running - starting" "error"
                        alarm "Starting $1 at $IDENTIFIER"
                        systemctl start "$1"
                        if [ $? -ne 0 ]; then
                            print_colour "Couldn't start" "$1"
                            alarm "Couldn't start $1 at $IDENTIFIER"
                        else
                            alarm_check_up "$1" "Service $1 started running again at $IDENTIFIER"
                        fi
                    fi
                fi
            fi
        fi
    else
        if service "$1" status >/dev/null; then
            alarm_check_up "$1" "Service $1 started running again at $IDENTIFIER"
            print_colour "$1" "running"
        else
            print_colour "$1" "not running" "error"
            alarm_check_down "$1" "Service $1 is not running at $IDENTIFIER"
            if [ "$AUTO_RESTART" == "1" ]; then
                if [[ "$1" == "freepbx" || "$1" == "asterisk" ]]; then
                    restart_asterisk
                else
                    time_diff=$(get_time_diff "$1")
                    if ((time_diff >= RESTART_ATTEMPT_INTERVAL)) || ((time_diff == 0)); then
                        print_colour "$1" "not running - starting" "error"
                        alarm "Starting $1 at $IDENTIFIER"
                        service "$1" start
                        if [ $? -ne 0 ]; then
                            print_colour "Couldn't start" "$1"
                            alarm "Couldn't start $1 at $IDENTIFIER"
                        else
                            alarm_check_up "$1" "Service $1 started running again at $IDENTIFIER"
                        fi
                    fi
                fi
            fi
        fi
    fi
}

function restart_asterisk() {
    for service in "${SERVICES[@]}"; do
        if containsElement "$service" "${IGNORED_SERVICES[@]}"; then
            continue
        fi
        if [ "$is_old" == "0" ]; then
            systemctl stop "$service"
            if [ $? -ne 0 ]; then
                print_colour "Couldn't restart" "$service"
                alarm "Couldn't restart ${SERVICES[2]} at $IDENTIFIER couldn't restart service $service"
                return
            fi
        else
            service "$service" stop
            if [ $? -ne 0 ]; then
                print_colour "Couldn't restart" "$service"
                alarm "Couldn't restart ${SERVICES[2]} at $IDENTIFIER couldn't restart service $service"
                return
            fi
        fi
    done
    if ! containsElement "monofon" "${IGNORED_SERVICES[@]}"; then
        OLDIFS=$IFS
        IFS=$'\n'
        if [ -z "$(command -v supervisorctl)" ]; then
            mono_services=$(supervisord ctl status | grep monofon | grep -i RUNNING)
        else
            mono_services=$(supervisorctl status 2>/dev/null | grep monofon | grep RUNNING)
        fi
        active_services=$(echo "$mono_services" | awk '{print $service}')
        for service in $active_services; do
            if containsElement "$service" "${IGNORED_SERVICES[@]}"; then
                continue
            fi
            if [ -z "$(command -v supervisorctl)" ]; then
                supervisord ctl stop "${service[1]}"
            else
                supervisorctl stop "${service[1]}"
            fi
        done
        IFS=$OLDIFS
    fi
    for service in $(printf '%s\n' "${SERVICES[@]}" | tac); do
        if containsElement "$service" "${IGNORED_SERVICES[@]}"; then
            continue
        fi
        if [ "$is_old" == "0" ]; then
            systemctl start "$service"
            if [ $? -ne 0 ]; then
                print_colour "Couldn't restart" "$service"
                alarm "Couldn't restart ${SERVICES[2]} at $IDENTIFIER couldn't restart service $service"
                return
            fi
        else
            service "$service" start
            if [ $? -ne 0 ]; then
                print_colour "Couldn't restart" "$service"
                alarm "Couldn't restart ${SERVICES[2]} at $IDENTIFIER couldn't restart service $service"
                return
            fi
        fi
    done
    if ! containsElement "monofon" "${IGNORED_SERVICES[@]}"; then
        OLDIFS=$IFS
        IFS=$'\n'
        for service in $active_services; do
            if containsElement "$service" "${IGNORED_SERVICES[@]}"; then
                continue
            fi
            if [ -z "$(command -v supervisorctl)" ]; then
                supervisord ctl start "${service[1]}"
            else
                supervisorctl start "${service[1]}"
            fi
        done
        IFS=$OLDIFS
    fi
    echo "Restarted ${BLUE_FG}${SERVICES[2]}${RESET}" "at $IDENTIFIER"
    alarm_check_up "Restarted ${SERVICES[2]} at $IDENTIFIER"
}

function check_monofon_services() {
    OLDIFS=$IFS
    IFS=$'\n'

    if [ -z "$(command -v supervisorctl)" ]; then
        mono_services=$(supervisord ctl status | grep monofon)
    else
        if [ -z "$(supervisorctl status | grep "unix://")" ]; then
            mono_services=$(supervisorctl status 2>/dev/null | grep monofon)
        else
            mono_services=$(supervisorctl -c /etc/supervisord.conf status 2>/dev/null | grep monofon)
        fi
    fi

    if [ -n "$mono_services" ]; then
        alarm_check_up "monofon_services" "Monofon services are available at $IDENTIFIER"

        for service in $mono_services; do
            if containsElement "$service" "${IGNORED_SERVICES[@]}"; then
                continue
            fi
            is_active=$(echo "$service" | awk '{print $2}')
            service_name=$(echo "$service" | awk '{print $1}')

            if [ "${is_active,,}" != 'running' ]; then
                print_colour "$service_name" "not running" "error"
                alarm_check_down "$service_name" "$service_name is not running at $IDENTIFIER"
                if [ "$AUTO_RESTART" == "1" ]; then
                    time_diff=$(get_time_diff "$service_name")
                    if ((time_diff >= RESTART_ATTEMPT_INTERVAL)) || ((time_diff == 0)); then
                        print_colour "$service_name" "not running - starting" "error"
                        alarm "Starting $service_name at $IDENTIFIER"
                        supervisorctl restart "$service_name"
                        if [ $? -ne 0 ]; then
                            print_colour "Couldn't restart" "$service"
                            alarm "Couldn't restart $service at $IDENTIFIER"
                        else
                            alarm_check_up "$service_name" "Service $service_name started running again at $IDENTIFIER"
                        fi
                    fi
                fi
            else
                alarm_check_up "$service_name" "Service $service_name started running again at $IDENTIFIER"
                print_colour "$service_name" "running"
            fi
        done
    else
        echo "${RED_FG}No monofon services found!${RESET}"
        alarm_check_down "monofon_services" "No monofon services found at $IDENTIFIER"
    fi

    IFS=$OLDIFS
}

function check_concurrent_calls() {
    echo_status "Checking the number of concurrent calls"
    active_calls=$(asterisk -rx "core show channels" | grep "active calls" | awk '{print $1}')

    if [ "$active_calls" -gt "$CONCURRENT_CALLS" ]; then
        alarm_check_down "active_calls" "Number of active calls at $IDENTIFIER is ${active_calls}"
        print_colour "Number of active calls" "${active_calls}" "error"
    else
        alarm_check_up "active_calls" "Number of active calls at $IDENTIFIER is below $CONCURRENT_CALLS - Active calls: ${active_calls}"
        print_colour "Number of active calls" "${active_calls}"
    fi
}

function check_trunks() {
    echo_status "Checking the statuses of the Trunks"
    trunk_list=$(asterisk -rx "sip show peers" | grep -E '^[a-zA-Z]' | sed '1d')

    OLDIFS=$IFS
    IFS=$'\n'
    for trunk in $trunk_list; do
        trunk_status=$(echo "$trunk" | awk '{print $6}')
        trunk_name=$(echo "$trunk" | awk '{print $1}')
        if [ $trunk_status != "OK" ]; then
            print_colour "$trunk_name" "${trunk_status}" "error"
            alarm_check_down "$trunk_name" "Trunk $trunk_name is ${trunk_status} at $IDENTIFIER" "trunk"
        else
            alarm_check_up "$trunk_name" "Trunk $trunk_name is ${trunk_status} again at $IDENTIFIER" "trunk"
            print_colour "$trunk_name" "OK"
        fi
    done
    IFS=$OLDIFS
}

function check_system_load_and_ram() {
    echo_status "Checking system load and RAM usage"
    load=$(uptime | awk -F'[a-z]:' '{ print $2 }' | awk '{print $1}' | cut -d',' -f1)
    if [ $is_old == 0 ]; then
        ram_usage=$(free -m | awk '/Mem/{printf("%.2f", $3/$2*100)}')
    else
        ram_usage=$(free -m | awk '/Mem/{printf("%.2f", ($3-$6-$7)/$2*100)}')
    fi

    if [ "$(echo "$load" | cut -d'.' -f1)" -gt "$LOAD_LIMIT" ]; then
        print_colour "System load" "greater than $LOAD_LIMIT" "error"
        alarm_check_down "sys_load" "System load at $IDENTIFIER is greater than $LOAD_LIMIT Load: $load"
    else
        print_colour "System load" "$load"
        alarm_check_up "sys_load" "System load at $IDENTIFIER returned to normal. Load: $load"
    fi

    if [ "$(echo "$ram_usage > $RAM_LIMIT" | bc)" -eq 1 ]; then
        print_colour "RAM usage" "above $RAM_LIMIT%" "error"
        alarm_check_down "ram_usage" "RAM usage at $IDENTIFIER is above $RAM_LIMIT% RAM usage: $ram_usage"
    else
        print_colour "RAM usage" "$ram_usage%"
        alarm_check_up "ram_usage" "RAM usage at $IDENTIFIER returned to normal. RAM usage: $ram_usage"
    fi
}

function get_time_diff() {
    [[ -z $1 ]] && {
        echo "Service name is not defined"
        return
    }
    service_name=$1
    service_name=$(echo "$service_name" | sed 's#/#-#g')
    file_path="/tmp/monofon-health/monofon_${service_name}_status.txt"

    if [ -f "${file_path}" ]; then

        old=$(date -d "$(awk '{print $1, $2}' <"${file_path}")" +%s)
        new=$(date -d "$(date '+%Y-%m-%d %H:%M')" +%s)

        time_diff=$(((new - old) / 60))

        if ((time_diff >= RESTART_ATTEMPT_INTERVAL)); then
            date "+%Y-%m-%d %H:%M" >"${file_path}"
        fi
    else
        date "+%Y-%m-%d %H:%M" >"${file_path}"
        time_diff=0
    fi

    echo $time_diff
}

function asterisk_error_check() {
    if tail /var/log/asterisk/full | grep -q Autodestruct; then
        alarm_check_down "autodestruct" "Found \"Autodestruct\" at log: /var/log/asterisk/full - Server: $IDENTIFIER"
    # else
    #     alarm_check_up "autodestruct" ""
    fi

    if [ $((10#$(date +%M) % 5)) -eq 0 ]; then
        if tail -n 1000 /var/log/asterisk/full | grep res_rtp_asterisk.so | grep Error; then
            alarm_check_down "module" "module alarm" # TODO alarm ekle
            asterisk -rx "module load res_pjproject.so"
            asterisk -rx "module load res_rtp_asterisk.so"
        fi
    fi
}

# function delete_time_diff() {
#     file_path="/tmp/monofon-health/monofon_$1_time.txt"
#     if [ -f "${file_path}" ]; then
#         rm -rf "${file_path}"
#     fi
# }

function alarm() {
    if [ "$SEND_ALARM" == "1" ]; then
        curl -fsSL -X POST -H "Content-Type: application/json" -d "{\"text\": \"$1\"}" "$ALARM_WEBHOOK_URL" 1>/dev/null
    fi
}

function alarm_check_down() {
    [[ -z $1 ]] && {
        echo "Service name is not defined"
        return
    }
    service_name=${1//\//-}
    file_path="/tmp/monofon-health/monofon_${service_name}_status.txt"

    if [ -z $3 ]; then
        if [ -f "${file_path}" ]; then
            old_date=$(awk '{print $1}' <"$file_path")
            current_date=$(date "+%Y-%m-%d")
            if [ "${old_date}" != "${current_date}" ]; then
                date "+%Y-%m-%d %H:%M" >"${file_path}"
                alarm "[Monofon - $IDENTIFIER] [:red_circle:] $2"
            fi
        else
            date "+%Y-%m-%d %H:%M" >"${file_path}"
            alarm "[Monofon - $IDENTIFIER] [:red_circle:] $2"
        fi
    else
        if [ -f "${file_path}" ]; then
            old_date=$(awk '{print $1}' <"$file_path")
            [[ -z $(awk '{print $3}' <"$file_path") ]] && locked=false || locked=true
            current_date=$(date "+%Y-%m-%d")
            if [ "${old_date}" != "${current_date}" ]; then
                date "+%Y-%m-%d %H:%M locked" >"${file_path}"
                alarm "[Monofon - $IDENTIFIER] [:red_circle:] $2"
            else
                if ! $locked; then
                    time_diff=$(get_time_diff "$1")
                    if ((time_diff >= TRUNK_CHECK_INTERVAL)); then
                        date "+%Y-%m-%d %H:%M locked" >"${file_path}"
                        alarm "[Monofon - $IDENTIFIER] [:red_circle:] $2"
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
    file_path="/tmp/monofon-health/monofon_${service_name}_status.txt"

    # delete_time_diff "$1"
    if [ -f "${file_path}" ]; then

        if [ -z $3 ]; then
            rm -rf "${file_path}"
            alarm "[Monofon - $IDENTIFIER] [:check:] $2"
        else
            [[ -z $(awk '{print $3}' <"$file_path") ]] && locked=false || locked=true
            rm -rf "${file_path}"
            if $locked; then
                alarm "[Monofon - $IDENTIFIER] [:check:] $2"
            fi
        fi
    fi

}

function check_db() {
    check_out=$(mysqlcheck --auto-repair --all-databases)
    tables=$(echo "$check_out" | sed -n '/Repairing tables/,$p' | tail -n +2)
    message=""
    if [ -n "$tables" ]; then
        message="[Monofon - $IDENTIFIER] [:info:] MySQL - \`mysqlcheck --auto-repair --all-databases\` result"
    fi
    oldIFS=$IFS
    IFS=$'\n'
    for table in $tables; do
        message="$message\n$table"
    done
    if [ -n "$message" ]; then
        alarm "$message"
    fi
    IFS=$oldIFS
}

check_voice_records() {
    echo_status "Checking Voice Recordings"
    # Since this only runs once a day and only checks todays recordings, older alarm file stays there.
    # So we check if any older alarm file exists and delete if it exists, since we don't need it anymore.
    old_alarm_path="/tmp/monofon-health/monofon_recording_folder_status.txt"
    if [ -f $old_alarm_path ]; then
        rm -rf $old_alarm_path
    fi

    recordings_path="/var/spool/asterisk/monitor/$(date "+%Y/%m/%d")"
    if [ -d "$recordings_path" ]; then
        file_count=$(ls $recordings_path | wc -l)
        if [ "$file_count" -eq 0 ]; then
            alarm "[Monofon - $IDENTIFIER] [:red_circle:] No recordings at: $recordings_path"
            print_colour "Number of Recordings" "No Recordings found" "error"
        else
            print_colour "Number of Recordings" "$file_count"
        fi
    else
        alarm_check_down "recording_folder" "Folder: $recordings_path doesn't exists. Creating..."
        echo "Folder: $recordings_path doesn't exists. Creating..."
        mkdir -p "$recordings_path"
        chown asterisk:asterisk "$recordings_path"
        if [ -d "$recordings_path" ]; then
            alarm_check_up "recording_folder" "Successfully created folder: $recordings_path"
            echo "Successfully created folder: $recordings_path"
        else
            alarm "[Monofon - $IDENTIFIER] [:red_circle:] Couldn't create folder: $recordings_path"
            echo "Couldn't create folder: $recordings_path"
        fi
    fi
}

function rewrite_monofon_data() {
    if ! containsElement "monofon" "${IGNORED_SERVICES[@]}"; then
        file="/tmp/monofon-health/rewrite-monofon-data-row-count.txt"
        if [[ -f /var/www/html/monofon-pano-yeni/scripts/asterniclog-manual-mysql.php ]] && ! containsElement "monofon" "${IGNORED_SERVICES[@]}"; then
            if [[ $(date "+%H:%M") == "01:00" ]]; then
                screen -dm php /var/www/html/monofon-pano-yeni/scripts/asterniclog-manual-mysql.php "$(date -d "yesterday" '+%Y-%m-%d')"
            fi
        fi

        if [ -f $file ]; then
            # row_count=$(cat $file)
            #alarm "Monofon verilerin yeniden yazılması tamamlandı. Satır sayısı: $row_count"
            rm $file
        fi
    fi
}

function check_data_file() {
    echo_status "Checking data.json"
    data_timestamp="/tmp/monofon-health/monofon_data-json.txt"
    data_file="/var/www/html/monofon-pano-yeni/data/data.json"
    if [ -f $data_timestamp ]; then
        before=$(cat $data_timestamp)
        now=$(stat -c %y $data_file)
        if [ "$before" == "$now" ]; then
            alarm_check_down "data-json" "No changes made to file: $data_file"
            print_colour "data.json" "not updated"
        else
            alarm_check_up "data-json" "Data file updated. File: $data_file"
            print_colour "data.json" "updated"
        fi
        echo "$now" >$data_timestamp
    fi
    stat -c %y $data_file >$data_timestamp
}

function main() {
    is_old=0
    # Checks if systemctl is present, if not it uses service instead
    if [ -z "$(command -v systemctl)" ]; then
        is_old=1
        SERVICES[2]="asterisk"
        SERVICES[4]="mysql"
        out=$(service mysql status 2>&1)
        if [ "$out" == "mysql: unrecognized service" ]; then
            SERVICES[4]="mysqld"
        fi
    fi
    echo "Monofon-health.sh started health check at $(date)"
    printf '\n'
    echo_status "Checking the statuses of the Services"
    for service in "${SERVICES[@]}"; do
        if containsElement "$service" "${IGNORED_SERVICES[@]}"; then
            continue
        fi
        check_service "$service"
    done
    if ! containsElement "monofon" "${IGNORED_SERVICES[@]}"; then
        check_monofon_services
    fi
    printf '\n'
    check_system_load_and_ram
    printf '\n'
    check_concurrent_calls
    printf '\n'
    check_trunks
    printf '\n'
    if [ $(date "+%H:%M") == "05:00" ]; then
        check_db
    fi
    asterisk_error_check
    if [ $(date "+%H:%M") == "12:00" ] && echo "$IDENTIFIER" | grep sip >/dev/null; then
        if ! containsElement "recordings" "${IGNORED_SERVICES[@]}"; then
            check_voice_records
        fi
    fi
    if ! containsElement "monofon" "${IGNORED_SERVICES[@]}"; then
        check_data_file
    fi
    rewrite_monofon_data
}

[[ "$1" == '-v' ]] || [[ "$1" == '--version' ]] && {
    echo "$VERSION"
    exit 0
}

pidfile=/var/run/monofon-health.sh.pid
if [ -f ${pidfile} ]; then
    lastpid=$(cat ${pidfile})

    if ps -p "${lastpid}" &>/dev/null; then
        if [ $(date "+%H") != "05" ]; then # mysqlcheck runs at 5 am and takes some time.
            alarm_check_down "still_running" "Last process is still running."
            echo "Last process is still running"
            exit 1
        fi
    else
        alarm_check_up "still_running" "Last process no longer runs. Removing stale pid file."
        rm ${pidfile} # pid file is stale, remove it
    fi
fi

alarm_check_up "still_running" "Last process completed."

echo $$ >${pidfile}

main

rm ${pidfile}
