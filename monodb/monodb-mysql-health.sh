#!/usr/bin/env bash
###~ description: Checks the status of MySQL and MySQL cluster
VERSION=v1.0.0

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

if [ -z "$ALARM_INTERVAL" ]; then
    ALARM_INTERVAL=3
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
          if [ -z "$ALARM_WEBHOOK_URLS" ]; then
	    curl -fsSL -X POST -H "Content-Type: application/json" -d "{\"text\": \"$1\"}" "$ALARM_WEBHOOK_URL" 1>/dev/null
	  else
	    for webhook in "${ALARM_WEBHOOK_URLS[@]}"; do
		curl -fsSL -X POST -H "Content-Type: application/json" -d "{\"text\": \"$1\"}" "$webhook" 1>/dev/null
	    done
	  fi
      fi
	
      if [ "$SEND_DM_ALARM" = "1" ] && [ -n "$ALARM_BOT_API_KEY" ] && [ -n "$ALARM_BOT_EMAIL" ] && [ -n "$ALARM_BOT_API_URL" ] && [ -n "$ALARM_BOT_USER_EMAILS" ]; then
            for user_email in "${ALARM_BOT_USER_EMAILS[@]}"; do
		curl -s -X POST "$ALARM_BOT_API_URL"/api/v1/messages \
		    -u "$ALARM_BOT_EMAIL:$ALARM_BOT_API_KEY" \
		    --data-urlencode type=direct \
		    --data-urlencode "to=$user_email" \
		    --data-urlencode "content=$1" 1> /dev/null
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
    file_path="/tmp/monodb-mysql-health/postal_${service_name}_status.txt"

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
    file_path="/tmp/monodb-mysql-health/postal_${service_name}_status.txt"

    if [ -z $3 ]; then
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
    else
        if [ -f "${file_path}" ]; then
            old_date=$(awk '{print $1}' <"$file_path")
            [[ -z $(awk '{print $3}' <"$file_path") ]] && locked=false || locked=true
            current_date=$(date "+%Y-%m-%d")
            if [ "${old_date}" != "${current_date}" ]; then
                date "+%Y-%m-%d %H:%M locked" >"${file_path}"
                alarm "[MySQL - $IDENTIFIER] [:red_circle:] $2"
            else
                if ! $locked; then
                    time_diff=$(get_time_diff "$1")
                    if ((time_diff >= ALARM_INTERVAL)); then
                        date "+%Y-%m-%d %H:%M locked" >"${file_path}"
                        alarm "[MySQL - $IDENTIFIER] [:red_circle:] $2"
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
    file_path="/tmp/monodb-mysql-health/postal_${service_name}_status.txt"

    # delete_time_diff "$1"
    if [ -f "${file_path}" ]; then
        if [ -z $3 ]; then
            rm -rf "${file_path}"
            alarm "[MySQL - $IDENTIFIER] [:check:] $2"
        else
            [[ -z $(awk '{print $3}' <"$file_path") ]] && locked=false || locked=true
            rm -rf "${file_path}"
            if $locked; then
                alarm "[MySQL - $IDENTIFIER] [:check:] $2"
            fi
        fi
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
        alarm_check_up "no_processes" "Number of processes is below limit: $processlist_count/$PROCESS_LIMIT" "process"
        print_colour "Number of Processes" "$processlist_count/$PROCESS_LIMIT"
    else
        alarm_check_down "no_processes" "Number of processes is above limit: $processlist_count/$PROCESS_LIMIT" "process"
        print_colour "Number of Processes" "$processlist_count/$PROCESS_LIMIT" "error"
    fi

}

function write_active_connections() {
    mkdir -p /var/log/monodb
    mysql -e "SELECT * FROM INFORMATION_SCHEMA.PROCESSLIST WHERE STATE = 'executing' AND USER != 'root' ORDER BY TIME DESC;" >/var/log/monodb/mysql-processlist-"$(date +"%a")".log
}

function check_active_connections() {
    echo_status "Active Connections"
    max_and_used=$(mysql -sNe "SELECT @@max_connections AS max_conn, (SELECT COUNT(*) FROM information_schema.processlist WHERE state = 'executing') AS used;")
    
    file="/tmp/monodb-mysql-health/last-connection-above-limit.txt"
    max_conn="$(echo "$max_and_used" | awk '{print $1}')"
    used_conn="$(echo "$max_and_used" | awk '{print $2}')"
  
    used_percentage=$(echo "$max_conn $used_conn" | awk '{print ($2*100/$1)}')
    if [ -f "$file" ]; then
        increase=$(cat $file)
    else
        increase=1
    fi
  
    if eval "$(echo "$used_percentage $CONN_LIMIT_PERCENT" | awk '{if ($1 >= $2) print "true"; else print "false"}')"; then
        alarm_check_down "active_conn" "Number of Active Connections is $used_conn ($used_percentage%) and Above $CONN_LIMIT_PERCENT%"
        print_colour "Number of Active Connections" "$used_conn ($used_percentage)% and Above $CONN_LIMIT_PERCENT%" "error"
        difference=$(((${used_percentage%.*} - ${CONN_LIMIT_PERCENT%.*}) / 10))
        if [[ $difference -ge $increase ]]; then
            write_active_connections
            if [ -f "$file" ]; then
                alarm "[MySQL - $IDENTIFIER] [:red_circle:] Number of Active Connections has passed $((CONN_LIMIT_PERCENT + (increase * 10)))% - It is now $used_conn ($used_percentage%)"
            fi
            increase=$((difference + 1))
        fi
        echo "$increase" >$file
    else
        alarm_check_up "active_conn" "Number of Active Connections is $used_conn ($used_percentage)% and Below $CONN_LIMIT_PERCENT%"
        print_colour "Number of Active Connections" "$used_conn ($used_percentage)% and Below $CONN_LIMIT_PERCENT%"
        rm -f $file
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
    check_active_connections
    printf '\n'
    if [ "$IS_CLUSTER" -eq 1 ]; then
        check_cluster_status
        check_node_status
        check_cluster_synced
        #check_flow_control
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
