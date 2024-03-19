#!/usr/bin/env bash
###~ description: Checks the status of MySQL and MySQL cluster
VERSION=v0.6.0

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
            alarm "[MySQL - $IDENTIFIER] [:red_circle:] $2"
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

function select_now() {
    echo_status "MySQL Access:"
    if mysql -sNe "SELECT NOW();" >/dev/null; then
        alarm_check_up "now" "Can run 'SELECT' statements again"
        print_colour "MySQL" "accessible"
    else
        alarm_check_down "now" "Couldn't run a 'SELECT' statement on MySQL"
        print_colour "MySQL" "not accessible" "error"
        exit 1
    fi
}

function check_process_count() {
    echo_status "Number of Processes:"
    processlist_count=$(/usr/bin/mysqladmin processlist | grep -vc 'show processlist')

    if [[ "$processlist_count" -lt "$PROCESS_LIMIT" ]]; then
        alarm_check_up "no_processes" "Number of processes is below limit: $processlist_count/$PROCESS_LIMIT"
        print_colour "Number of Processes" "$processlist_count/$PROCESS_LIMIT"
    else
        alarm_check_down "no_processes" "Number of processes is above limit: $processlist_count/$PROCESS_LIMIT"
        print_colour "Number of Processes" "$processlist_count/$PROCESS_LIMIT" "error"
    fi

}

function check_cluster_status() {
    echo_status "Cluster Status:"
    cluster_status=$(mysql -sNe "SHOW STATUS WHERE Variable_name = 'wsrep_cluster_size';")
    no_cluster=$(echo "$cluster_status" | awk '{print $2}')
    if [ "$no_cluster" -eq "$CLUSTER_SIZE" ]; then
        alarm_check_up "cluster_size" "Cluster size is accurate: $no_cluster/$CLUSTER_SIZE"
        print_colour "Cluster size" "$no_cluster/$CLUSTER_SIZE"
    elif [ -z "$no_cluster" ]; then
        alarm_check_down "cluster_size" "Couldn't get cluster size: $no_cluster/$CLUSTER_SIZE"
        print_colour "Cluster size" "Couln't get" "error"
    else
        alarm_check_down "cluster_size" "Cluster size is not accurate: $no_cluster/$CLUSTER_SIZE"
        print_colour "Cluster size" "$no_cluster/$CLUSTER_SIZE" "error"
    fi
}

function check_node_status() {
    output=$(mysql -sNe "SHOW STATUS WHERE Variable_name = 'wsrep_ready';")
    name=$(echo "$output" | awk '{print $1}')
    is_available=$(echo "$output" | awk '{print $2}')
    if [ -n "$is_available" ]; then
        alarm_check_up "is_available" "Node status $name is $is_available"
        print_colour "Node status" "$is_available"
    elif [ -z "$name" ] || [ -z "$is_available" ]; then
        alarm_check_down "is_available" "Node status couldn't get a response from MySQL"
        print_colour "Node status" "Couldn't get info" "error"
    else
        alarm_check_down "is_available" "Node status $name is $is_available"
        print_colour "Node status" "$is_available" "error"
    fi
}

function check_cluster_synced() {
    output=$(mysql -sNe "SHOW STATUS WHERE Variable_name = 'wsrep_local_state_comment';")
    name=$(echo "$output" | awk '{print $1}')
    is_synced=$(echo "$output" | awk '{print $2}')
    if [ -n "$is_synced" ]; then
        alarm_check_up "is_synced" "Node local state $name is $is_synced"
        print_colour "Node local state" "$is_synced"
    elif [ -z "$name" ] || [ -z "$is_synced" ]; then
        alarm_check_down "is_synced" "Node local state couldn't get a response from MySQL"
        print_colour "Node local state" "Couldn't get info" "error"
    else
        alarm_check_down "is_synced" "Node local state $name is $is_synced"
        print_colour "Node local state" "$is_synced" "error"
    fi
}

function check_flow_control() {
    output=$(mysql -sNe "SHOW STATUS WHERE Variable_name = 'wsrep_flow_control_paused';")
    name=$(echo "$output" | awk '{print $1}')
    stop_time=$(echo "$output" | awk '{print $2}' | cut -c 1)
    if [ "$stop_time" -gt 0 ]; then
        alarm_check_down "flow" "Replication paused by Flow Control more than 1 second - $stop_time"
        print_colour "Replication pause time" "$stop_time" "error"
    else
        alarm_check_up "flow" "Replication paused by Flow Control less than 1 second again - $stop_time"
        print_colour "Replication pause time" "$stop_time"
    fi
}

function check_db() {
    check_out=$(mysqlcheck --auto-repair --all-databases)
    tables=$(echo "$check_out" | sed -n '/Repairing tables/,$p' | tail -n +2)
    message=""
    if [ -n "$tables" ]; then
        message="[MySQL - $IDENTIFIER] [:info:] MySQL - \`mysqlcheck --auto-repair --all-databases\` result"
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

function main() {
    printf '\n'
    echo  MonoDB MySQL Health $VERSION - "$(date)"  
    printf '\n'
    select_now
    printf '\n'
    check_process_count
    printf '\n'
    if [ "$IS_CLUSTER" -eq 1 ]; then
        check_cluster_status
        check_node_status
        check_cluster_synced
        check_flow_control
    fi

    if [ "$(date "+%H:%M")" == "05:00" ]; then
        check_db
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
