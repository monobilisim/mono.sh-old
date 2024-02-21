#!/usr/bin/env bash
###~ description: Checks the status of MySQL and MySQL cluster
VERSION=v0.1.0

[[ "$1" == '-v' ]] || [[ "$1" == '--version' ]] && {
    echo "$VERSION"
    exit 0
}

mkdir -p /tmp/monodb-mysql-health

if [[ -f /etc/monodb-mysql-health.conf ]]; then
    . /etc/monodb-mysql-health.conf
else
    echo "Config file doesn't exists at /etc/monodb-mysql-health.conf"
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
    file_path="/tmp/monodb-mysql-health/postal_${service_name}_status.txt"

    if [ -f "${file_path}" ]; then
        old_date=$(awk '{print $1}' <"$file_path")
        current_date=$(date "+%Y-%m-%d")
        if [ "${old_date}" != "${current_date}" ]; then
            date "+%Y-%m-%d %H:%M" >"${file_path}"
            alarm "$2"
        fi
    else
        date "+%Y-%m-%d %H:%M" >"${file_path}"
        alarm "[MySQL - $IDENTIFIER] [:red_circle:] $2"
    fi

}

function alarm_check_up() {
    [[ -z $1 ]] && {
        echo "Service name is not defined"
        return
    }
    service_name=${1//\//-}
    file_path="/tmp/monodb-mysql-health/postal_${service_name}_status.txt"

    # delete_time_diff "$1"
    if [ -f "${file_path}" ]; then
        rm -rf "${file_path}"
        alarm "[MySQL - $IDENTIFIER] [:check:] $2"
    fi
}

function check_process_count() {
    echo_status "Number of Processes:"
    processlist_count=$(/usr/bin/mysqladmin processlist | grep -vc 'show processlist')

    if [[ "$processlist_count" -lt "$PROCESS_LIMIT" ]]; then
        alarm_check_up "no_processes" "Number of processes is below limit: $processlist_count/$PROCESS_LIMIT at $IDENTIFIER"
        print_colour "Number of Processes" "$processlist_count/$PROCESS_LIMIT"
    else
        alarm_check_down "no_processes" "Number of processes is above limit: $processlist_count/$PROCESS_LIMIT at $IDENTIFIER"
        print_colour "Number of Processes" "$processlist_count/$PROCESS_LIMIT" "error"
    fi

}

function check_cluster_status() {
    echo_status "Cluster Status:"
    cluster_status=$(mysql -sNe "SHOW STATUS WHERE Variable_name = 'wsrep_cluster_size';")
    no_cluster=$(echo "$cluster_status" | awk '{print $2}')
    if [ "$no_cluster" -eq "$CLUSTER_SIZE" ]; then
        alarm_check_up "cluster_size" "Cluster size is accurate: $no_cluster/$CLUSTER_SIZE at $IDENTIFIER"
        print_colour "Cluster size" "$no_cluster/$CLUSTER_SIZE"
    elif [ -z "$no_cluster" ]; then
        alarm_check_down "cluster_size" "Couldn't get cluster size: $no_cluster/$CLUSTER_SIZE at $IDENTIFIER"
        print_colour "Cluster size" "Couln't get" "error"
    else
        alarm_check_down "cluster_size" "Cluster size is not accurate: $no_cluster/$CLUSTER_SIZE at $IDENTIFIER"
        print_colour "Cluster size" "$no_cluster/$CLUSTER_SIZE" "error"
    fi
}

function check_node_status() {
    output=$(mysql -sNe "SHOW STATUS WHERE Variable_name = 'wsrep_ready';")
    name=$(echo "$output" | awk '{print $1}')
    is_available=$(echo "$output" | awk '{print $2}')
    if [ -n "$is_available" ]; then
        alarm_check_up "is_available" "Node status $name is $is_available at $IDENTIFIER"
        print_colour "$name" "$is_available"
    elif [ -z "$name" ] || [ -z "$is_available" ]; then
        alarm_check_down "is_available" "Node status couldn't get a response from MySQL at $IDENTIFIER"
        print_colour "Node status" "Couldn't get info" "error"
    else
        alarm_check_down "is_available" "Node status $name is $is_available at $IDENTIFIER"
        print_colour "$name" "$is_available" "error"
    fi
}

function check_cluster_synced() {
    output=$(mysql -sNe "SHOW STATUS WHERE Variable_name = 'wsrep_local_state_comment';")
    name=$(echo "$output" | awk '{print $1}')
    is_synced=$(echo "$output" | awk '{print $2}')
    if [ -n "$is_synced" ]; then
        alarm_check_up "is_synced" "Cluster sync status $name is $is_synced at $IDENTIFIER"
        print_colour "$name" "$is_synced"
    elif [ -z "$name" ] || [ -z "$is_synced" ]; then
        alarm_check_down "is_synced" "Cluster sync status couldn't get a response from MySQL $IDENTIFIER"
        print_colour "Cluster sync status" "Couldn't get info" "error"
    else
        alarm_check_down "is_synced" "Cluster sync status $name is $is_synced $IDENTIFIER"
        print_colour "$name" "$is_synced" "error"
    fi
}

function main() {
    printf '\n'
    echo "Monodb MySQL Health $VERSION - $(date)"
    printf '\n'
    check_process_count
    printf '\n'
    if [ "$IS_CLUSTER" -eq 1 ]; then
        check_cluster_status
        check_node_status
        check_cluster_synced
    fi
}

pidfile=/var/run/monodb-mysql-health.sh.pid
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

