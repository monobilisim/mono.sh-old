#!/usr/bin/env bash
###~ description: Checks the status of pmg and related services

VERSION=v1.0.0

[[ "$1" == '-v' ]] || [[ "$1" == '--version' ]] && {
    echo "$VERSION"
    exit 0
}

mkdir -p /tmp/monomail-pmg-health

# https://stackoverflow.com/questions/4774054/reliable-way-for-a-bash-script-to-get-the-full-path-to-itself
SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 || exit ; pwd -P )"

. "$SCRIPTPATH"/common.sh

parse_config_pmg() {
    CONFIG_PATH_PMG="mail"
    export REQUIRED=true
    
    QUEUE_LIMIT=$(yaml .pmg.queue_limit $CONFIG_PATH_PMG)

    SEND_ALARM=$(yaml .alarm.enabled $CONFIG_PATH_POSTAL "$SEND_ALARM")
}

parse_config_pmg

if [ -z "$ALARM_INTERVAL" ]; then
    ALARM_INTERVAL=3
fi

RED_FG=$(tput setaf 1)
GREEN_FG=$(tput setaf 2)
BLUE_FG=$(tput setaf 4)
RESET=$(tput sgr0)

pmg_services=("pmgproxy.service" "pmg-smtp-filter.service" "postfix@-.service")

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

function alarm() {
      if [ "$SEND_ALARM" == "1" ]; then
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

function alarm() {
    if [ "$SEND_ALARM" == "1" ]; then
        curl -fsSL -X POST -H "Content-Type: application/json" -d "{\"text\": \"$1\"}" "$ALARM_WEBHOOK_URL" 1>/dev/null
    fi
}

function get_time_diff() {
    [[ -z $1 ]] && {
        echo "Service name is not defined"
        return
    }
    service_name=$1
    service_name=$(echo "$service_name" | sed 's#/#-#g')
    file_path="/tmp/monomail-pmg-health/postal_${service_name}_status.txt"

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
    file_path="/tmp/monomail-pmg-health/postal_${service_name}_status.txt"

    if [ -z $3 ]; then
        if [ -f "${file_path}" ]; then
            old_date=$(awk '{print $1}' <"$file_path")
            current_date=$(date "+%Y-%m-%d")
            if [ "${old_date}" != "${current_date}" ]; then
                date "+%Y-%m-%d %H:%M" >"${file_path}"
                alarm "[PMG - $IDENTIFIER] [:red_circle:] $2"
            fi
        else
            date "+%Y-%m-%d %H:%M" >"${file_path}"
            alarm "[PMG - $IDENTIFIER] [:red_circle:] $2"
        fi
    else
        if [ -f "${file_path}" ]; then
            old_date=$(awk '{print $1}' <"$file_path")
            [[ -z $(awk '{print $3}' <"$file_path") ]] && locked=false || locked=true
            current_date=$(date "+%Y-%m-%d")
            if [ "${old_date}" != "${current_date}" ]; then
                date "+%Y-%m-%d %H:%M locked" >"${file_path}"
                alarm "[PMG - $IDENTIFIER] [:red_circle:] $2"
            else
                if ! $locked; then
                    time_diff=$(get_time_diff "$1")
                    if ((time_diff >= ALARM_INTERVAL)); then
                        date "+%Y-%m-%d %H:%M locked" >"${file_path}"
                        alarm "[PMG - $IDENTIFIER] [:red_circle:] $2"
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
    file_path="/tmp/monomail-pmg-health/postal_${service_name}_status.txt"

    # delete_time_diff "$1"
    if [ -f "${file_path}" ]; then

        if [ -z $3 ]; then
            rm -rf "${file_path}"
            alarm "[PMG - $IDENTIFIER] [:check:] $2"
        else
            [[ -z $(awk '{print $3}' <"$file_path") ]] && locked=false || locked=true
            rm -rf "${file_path}"
            if $locked; then
                alarm "[PMG - $IDENTIFIER] [:check:] $2"
            fi
        fi
    fi
}

function check_pmg_services() {
    echo_status "PMG Services"
    for i in "${pmg_services[@]}"; do
        if systemctl status "$i" >/dev/null; then
            print_colour "$i" "running"
            alarm_check_up "$i" "Service $i is working again" "service"
        else
            print_colour "$i" "not running" "error"
            alarm_check_down "$i" "Service $i is not working" "service"
        fi
    done
}

function postgresql_status() {
    echo_status "PostgreSQL Status"
    if pg_isready -q; then
        alarm_check_up "postgresql" "PostgreSQL is working again"
        print_colour "PostgreSQL" "running"
    else
        alarm_check_down "postgresql" "PostgreSQL is not working"
        print_colour "PostgreSQL" "not running" "error"
    fi
}

function queued_messages() {
    echo_status "Queued Messages"
    queue=$(mailq | grep -c "^[A-F0-9]")
    if [ "$queue" -lt $QUEUE_LIMIT ]; then
        print_colour "Number of queued messages" "$queue"
        alarm_check_up "queued" "Number of queued messages is acceptable - $queue/$QUEUE_LIMIT" "queue"
    else
        print_colour "Number of queued messages" "$queue" "error"
        alarm_check_down "queued" "Number of queued messages is above limit - $queue/$QUEUE_LIMIT" "queue"
    fi
}

function main() {
    printf '\n'
    echo "Monomail PMG Health $VERSION - $(date)"
    printf '\n'
    check_pmg_services
    printf '\n'
    postgresql_status
    printf '\n'
    queued_messages
}

pidfile=/var/run/monomail-pmg-health.sh.pid
if [ -f ${pidfile} ]; then
    oldpid=$(cat ${pidfile})

    if ! ps -p "${oldpid}" &>/dev/null; then
        rm ${pidfile} # pid file is stale, remove it
    else
        echo "Old process still running"
        exit 1
    fi
fi

echo $$ >${pidfile}

main

rm ${pidfile}
