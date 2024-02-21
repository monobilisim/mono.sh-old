#!/usr/bin/env bash
###~ description: Checks the status of pmg and related services

VERSION=v0.1.0

[[ "$1" == '-v' ]] || [[ "$1" == '--version' ]] && {
    echo "$VERSION"
    exit 0
}

mkdir -p /tmp/monomail-pmg-health

if [[ -f /etc/monomail-pmg-health.conf ]]; then
    . /etc/monomail-pmg-health.conf
else
    echo "Config file doesn't exists at /etc/monomail-pmg-health.conf"
    exit 1
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
        curl -fsSL -X POST -H "Content-Type: application/json" -d "{\"text\": \"$1\"}" "$ALARM_WEBHOOK_URL" 1>/dev/null
    fi
}

function alarm_check_down() {
    [[ -z $1 ]] && {
        echo "Service name is not defined"
        return
    }
    service_name=${1//\//-}
    file_path="/tmp/monomail-pmg-health/postal_${service_name}_status.txt"

    if [ -f "${file_path}" ]; then
        old_date=$(awk '{print $1}' <"$file_path")
        current_date=$(date "+%Y-%m-%d")
        if [ "${old_date}" != "${current_date}" ]; then
            date "+%Y-%m-%d %H:%M" >"${file_path}"
            alarm "$2"
        fi
    else
        date "+%Y-%m-%d %H:%M" >"${file_path}"
        alarm "[PMG - $IDENTIFIER] [:red_circle:] $2"
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
        rm -rf "${file_path}"
        alarm "[PMG - $IDENTIFIER] [:check:] $2"
    fi
}

function check_pmg_services() {
    echo_status "PMG Services"
    for i in "${pmg_services[@]}"; do
        if systemctl status "$i" >/dev/null; then
            alarm_check_up "$i" "Service $i is working again"
            print_colour "$i" "running"
        else
            alarm_check_down "$i" "Service $i is not working"
            print_colour "$i" "not running" "error"
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
        alarm_check_up "queued" "Number of queued messages is acceptable - $queue/$QUEUE_LIMIT"
        print_colour "Number of queued messages" "$queue"
    else
        alarm_check_down "queued" "Number of queued messages is above limit - $queue/$QUEUE_LIMIT"
        print_colour "Number of queued messages" "$queue" "error"
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
