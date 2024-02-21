#!/usr/bin/env bash
###~ description: Checks the status of PostgreSQL and Patroni cluster

VERSION=v0.1.0

[[ "$1" == '-v' ]] || [[ "$1" == '--version' ]] && {
    echo "$VERSION"
    exit 0
}

mkdir -p /tmp/monodb-pgsql-patroni-health

if [[ -f /etc/monodb-pgsql-patroni-health.conf ]]; then
    . /etc/monodb-pgsql-patroni-health.conf
else
    echo "Config file doesn't exists at /etc/monodb-pgsql-patroni-health.conf"
    exit 1
fi

RED_FG=$(tput setaf 1)
GREEN_FG=$(tput setaf 2)
BLUE_FG=$(tput setaf 4)
RESET=$(tput sgr0)

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
    file_path="/tmp/monodb-pgsql-patroni-health/postal_${service_name}_status.txt"

    if [ -f "${file_path}" ]; then
        old_date=$(awk '{print $1}' <"$file_path")
        current_date=$(date "+%Y-%m-%d")
        if [ "${old_date}" != "${current_date}" ]; then
            date "+%Y-%m-%d %H:%M" >"${file_path}"
            alarm "$2"
        fi
    else
        date "+%Y-%m-%d %H:%M" >"${file_path}"
        alarm "[Patroni - $IDENTIFIER] [:red_circle:] $2"
    fi

}

function alarm_check_up() {
    [[ -z $1 ]] && {
        echo "Service name is not defined"
        return
    }
    service_name=${1//\//-}
    file_path="/tmp/monodb-pgsql-patroni-health/postal_${service_name}_status.txt"

    # delete_time_diff "$1"
    if [ -f "${file_path}" ]; then
        rm -rf "${file_path}"
        alarm "[Patroni - $IDENTIFIER] [:check:] $2"
    fi
}

function patroni_status() {
    echo_status "Patroni Status"
    if systemctl status patroni.service >/dev/null; then
        print_colour "Patroni" "Active"
        alarm_check_up "patroni" "Patroni is active again!"
    else
        print_colour "Patroni" "Active" "error"
        alarm_check_down "patroni" "Patroni is not active!"
    fi
}

function cluster_role() {
    echo_status "Cluster Roles"
    if ! curl -s "$PATRONI_API" >/dev/null; then
        print_colour "Patroni API" "not accessible" "error"
        alarm_check_down "patroni_api" "Can't access Patroni API through: $PATRONI_API"
        return
    fi
    alarm_check_up "patroni_api" "Patroni API is accessible again through: $PATRONI_API"
    mapfile -t cluster_names < <(curl -s "$PATRONI_API" | jq -r '.members[] | .name ')
    mapfile -t cluster_roles < <(curl -s "$PATRONI_API" | jq -r '.members[] | .role')
    i=0
    for cluster in "${cluster_names[@]}"; do
        print_colour "$cluster" "${cluster_roles[$i]}"
        if
            [ -f /tmp/monodb-pgsql-patroni-health/raw_output.json ] &&
                old_role="$(jq -r '.members['"$i"'] | .role' </tmp/monodb-pgsql-patroni-health/raw_output.json)"
            [ "${cluster_roles[$i]}" != "$old_role" ] &&
                [ "$cluster" == "$(jq -r '.members['"$i"'] | .name' </tmp/monodb-pgsql-patroni-health/raw_output.json)" ]
        then
            echo "  Role of $cluster has changed!"
            print_colour "  Old Role of $cluster" "$old_role" "error"
            printf '\n'
            alarm "[Patroni - $IDENTIFIER] [:info:] Role of $cluster has changed! Old: **$old_role**, Now: **${cluster_roles[$i]}**"
            [ "${cluster_roles[$i]}" == "leader" ] && alarm "[Patroni - $IDENTIFIER] [:check:] New leader is $cluster!"
        fi
        i=$((i + 1))
    done
    curl -s "$PATRONI_API" | jq >/tmp/monodb-pgsql-patroni-health/raw_output.json
}

function cluster_state() {
    echo_status "Cluster States"
    if ! curl -s "$PATRONI_API" >/dev/null; then
        print_colour "Patroni API" "not accessible" "error"
        alarm_check_down "patroni_api" "Can't access Patroni API through: $PATRONI_API"
        return
    fi
    alarm_check_up "patroni_api" "Patroni API is accessible again through: $PATRONI_API"
    mapfile -t cluster_names < <(curl -s "$PATRONI_API" | jq -r '.members[] | .name ')
    mapfile -t cluster_states < <(curl -s "$PATRONI_API" | jq -r '.members[] | .state')
    i=0
    for cluster in "${cluster_names[@]}"; do
        if [ "${cluster_states[$i]}" == "running" ] || [ "${cluster_states[$i]}" == "streaming" ]; then
            print_colour "$cluster" "${cluster_states[$i]}"
            alarm_check_up "$cluster" "Cluster $cluster, is ${cluster_states[$i]} again"
        else
            print_colour "$cluster" "${cluster_states[$i]}" "error"
            alarm_check_down "$cluster" "Cluster $cluster, is ${cluster_states[$i]}"
        fi
        i=$((i + 1))
    done
}

function main() {
    printf '\n'
    echo "Monodb PostgreSQL Patroni Health $VERSION - $(date)"
    printf '\n'
    patroni_status
    printf '\n'
    cluster_role
    printf '\n'
    cluster_state
}

pidfile=/var/run/monodb-pgsql-patroni-health.sh.pid
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
