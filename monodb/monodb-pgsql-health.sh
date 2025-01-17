#!/usr/bin/env bash
###~ description: Checks the status of PostgreSQL and Patroni cluster
VERSION=v1.2.0

[[ "$1" == '-v' ]] || [[ "$1" == '--version' ]] && {
    echo "$VERSION"
    exit 0
}

mkdir -p /tmp/monodb-pgsql-health

if [[ -f /etc/monodb-pgsql-health.conf ]]; then
    . /etc/monodb-pgsql-health.conf
else
    echo "Config file doesn't exists at /etc/monodb-pgsql-health.conf"
    exit 1
fi

# https://github.com/mikefarah/yq v4.43.1 sürümü ile test edilmiştir
if [ -z "$(command -v yq)" ]; then

    if [[ "$1" == "--yq" ]]; then
        echo "Couldn't find yq. Installing it..."
        yn="y"
    else
        read -r -p "Couldn't find yq. Do you want to download it and put it under /usr/local/bin? [y/n]: " yn
    fi

    case $yn in
    [Yy]*)
        curl -sL "$(curl -s https://api.github.com/repos/mikefarah/yq/releases/latest | grep browser_download_url | cut -d\" -f4 | grep 'yq_linux_amd64' | grep -v 'tar.gz')" --output /usr/local/bin/yq
        chmod +x /usr/local/bin/yq
        ;;
    [Nn]*)
        echo "Aborted"
        exit 1
        ;;
    esac
fi

if [ -z "$ALARM_INTERVAL" ]; then
    ALARM_INTERVAL=3
fi

if [ -z "$PATRONI_API" ] && [ -f /etc/patroni/patroni.yml ]; then
    PATRONI_API="$(yq -r .restapi.listen /etc/patroni/patroni.yml)"
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
    file_path="/tmp/monodb-pgsql-health/patroni_${service_name}_status.txt"

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
    file_path="/tmp/monodb-pgsql-health/patroni_${service_name}_status.txt"

    if [ -z $3 ]; then
        if [ -f "${file_path}" ]; then
            old_date=$(awk '{print $1}' <"$file_path")
            current_date=$(date "+%Y-%m-%d")
            if [ "${old_date}" != "${current_date}" ]; then
                date "+%Y-%m-%d %H:%M" >"${file_path}"
                alarm "[PostgreSQL - $IDENTIFIER] [:red_circle:] $2"
            fi
        else
            date "+%Y-%m-%d %H:%M" >"${file_path}"
            alarm "[PostgreSQL - $IDENTIFIER] [:red_circle:] $2"
        fi
    else
        if [ -f "${file_path}" ]; then
            old_date=$(awk '{print $1}' <"$file_path")
            [[ -z $(awk '{print $3}' <"$file_path") ]] && locked=false || locked=true
            current_date=$(date "+%Y-%m-%d")
            if [ "${old_date}" != "${current_date}" ]; then
                date "+%Y-%m-%d %H:%M locked" >"${file_path}"
                alarm "[PostgreSQL - $IDENTIFIER] [:red_circle:] $2"
            else
                if ! $locked; then
                    time_diff=$(get_time_diff "$1")
                    if ((time_diff >= ALARM_INTERVAL)); then
                        date "+%Y-%m-%d %H:%M locked" >"${file_path}"
                        alarm "[PostgreSQL - $IDENTIFIER] [:red_circle:] $2"
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
    file_path="/tmp/monodb-pgsql-health/patroni_${service_name}_status.txt"

    # delete_time_diff "$1"
    if [ -f "${file_path}" ]; then
        if [ -z $3 ]; then
            rm -rf "${file_path}"
            alarm "[PostgreSQL - $IDENTIFIER] [:check:] $2"
        else
            [[ -z $(awk '{print $3}' <"$file_path") ]] && locked=false || locked=true
            rm -rf "${file_path}"
            if $locked; then
                alarm "[PostgreSQL - $IDENTIFIER] [:check:] $2"
            fi
        fi
    fi
}

function postgresql_status() {
    echo_status "PostgreSQL Status"
    if systemctl status postgresql.service &>/dev/null || systemctl status postgresql*.service >/dev/null; then
        print_colour "PostgreSQL" "Active"
        alarm_check_up "postgresql" "PostgreSQL is active again!"
    else
        print_colour "PostgreSQL" "Active" "error"
        alarm_check_down "postgresql" "PostgreSQL is not active!"
    fi
}

function pgsql_uptime() {
    # SELECT current_timestamp - pg_postmaster_start_time();
    #su - postgres -c "psql -c 'SELECT current_timestamp - pg_postmaster_start_time();'" | awk 'NR==3'
    echo_status "PostgreSQL Uptime:"
    # shellcheck disable=SC2037
    if grep iasdb /etc/passwd &>/dev/null; then
        # shellcheck disable=SC2037
        command="su - iasdb -c \"psql -c 'SELECT current_timestamp - pg_postmaster_start_time();'\""
    elif grep gitlab-psql /etc/passwd &>/dev/null; then
        # shellcheck disable=SC2037
        command="gitlab-psql -c 'SELECT current_timestamp - pg_postmaster_start_time();'"
    else
        # shellcheck disable=SC2037
        command="su - postgres -c \"psql -c 'SELECT current_timestamp - pg_postmaster_start_time();'\""
    fi

    if eval "$command" &>/dev/null; then
        uptime="$(eval $command | awk 'NR==3' | xargs)"
        alarm_check_up "now" "Can run 'SELECT' statements again"
        print_colour "Uptime" "$uptime"
    else
        alarm_check_down "now" "Couldn't run a 'SELECT' statement on PostgreSQL"
        print_colour "Uptime" "not accessible" "error"
        exit 1
    fi
}

function write_active_connections() {
    mkdir -p /var/log/monodb
    if grep iasdb /etc/passwd &>/dev/null; then
        su - iasdb -c "psql -c \"SELECT pid,usename, client_addr, now() - pg_stat_activity.query_start AS duration, query, state FROM pg_stat_activity  WHERE state='active' ORDER BY duration DESC;\"" >/var/log/monodb/pgsql-stat_activity-"$(date +"%a")".log
    elif grep gitlab-psql /etc/passwd &>/dev/null; then
        gitlab-psql -c "SELECT pid,usename, client_addr, now() - pg_stat_activity.query_start AS duration, query, state FROM pg_stat_activity  WHERE state='active' ORDER BY duration DESC;" >/var/log/monodb/pgsql-stat_activity-"$(date +"%a")".log
    else
        su - postgres -c "psql -c \"SELECT pid,usename, client_addr, now() - pg_stat_activity.query_start AS duration, query, state FROM pg_stat_activity  WHERE state='active' ORDER BY duration DESC;\"" >/var/log/monodb/pgsql-stat_activity-"$(date +"%a")".log
    fi
}

function check_active_connections() {
    echo_status "Active Connections"
    if grep iasdb /etc/passwd &>/dev/null; then
        max_and_used=$(su - iasdb -c "psql -c \"SELECT max_conn, used FROM (SELECT COUNT(*) used FROM pg_stat_activity) t1, (SELECT setting::int max_conn FROM pg_settings WHERE name='max_connections') t2;\"" | awk 'NR==3')
    elif grep gitlab-psql /etc/passwd &>/dev/null; then
        max_and_used=$(gitlab-psql -c "SELECT max_conn, used FROM (SELECT COUNT(*) used FROM pg_stat_activity) t1, (SELECT setting::int max_conn FROM pg_settings WHERE name='max_connections') t2;" | awk 'NR==3')
    else
        max_and_used=$(su - postgres -c "psql -c \"SELECT max_conn, used FROM (SELECT COUNT(*) used FROM pg_stat_activity) t1, (SELECT setting::int max_conn FROM pg_settings WHERE name='max_connections') t2;\"" | awk 'NR==3')
    fi

    file="/tmp/monodb-pgsql-health/last-connection-above-limit.txt"
    max_conn="$(echo "$max_and_used" | awk '{print $1}')"
    used_conn="$(echo "$max_and_used" | awk '{print $3}')"

    used_percentage=$(echo "$max_conn $used_conn" | awk '{print ($2*100/$1)}')
    if [ -f "$file" ]; then
        increase=$(cat $file)
    else
        increase=1
    fi

    if eval "$(echo "$used_percentage $CONN_LIMIT_PERCENT" | awk '{if ($1 >= $2) print "true"; else print "false"}')"; then
        if [ ! -f /tmp/monodb-pgsql-health/patroni_active_conn_status.txt ]; then
            write_active_connections
        fi
        alarm_check_down "active_conn" "Number of Active Connections is $used_conn ($used_percentage%) and Above $CONN_LIMIT_PERCENT%"
        print_colour "Number of Active Connections" "$used_conn ($used_percentage)% and Above $CONN_LIMIT_PERCENT%" "error"
        difference=$(((${used_percentage%.*} - ${CONN_LIMIT_PERCENT%.*}) / 10))
        if [[ $difference -ge $increase ]]; then
            write_active_connections
            if [ -f "$file" ]; then
                alarm "[PostgreSQL - $IDENTIFIER] [:red_circle:] Number of Active Connections has passed $((CONN_LIMIT_PERCENT + (increase * 10)))% - It is now $used_conn ($used_percentage%)"
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

function check_running_queries() {
    echo_status "Active Queries"
    if grep iasdb /etc/passwd &>/dev/null; then
        queries=$(su - iasdb -c "psql -c \"SELECT COUNT(*) AS active_queries_count FROM pg_stat_activity WHERE state = 'active';\"" | awk 'NR==3 {print $1}')
    elif grep gitlab-psql /etc/passwd &>/dev/null; then
        queries=$(gitlab-psql -c "SELECT COUNT(*) AS active_queries_count FROM pg_stat_activity WHERE state = 'active';" | awk 'NR==3 {print $1}')
    else
        queries=$(su - postgres -c "psql -c \"SELECT COUNT(*) AS active_queries_count FROM pg_stat_activity WHERE state = 'active';\"" | awk 'NR==3 {print $1}')
    fi

    # SELECT COUNT(*) AS active_queries_count FROM pg_stat_activity WHERE state = 'active';
    if [[ "$queries" -gt "$QUERY_LIMIT" ]]; then
        alarm_check_down "query_limit" "Number of Active Queries is $queries/$QUERY_LIMIT" "active_queries"
        print_colour "Number of Active Queries" "$queries/$QUERY_LIMIT" "error"
    else
        alarm_check_up "query_limit" "Number of Active Queries is $queries/$QUERY_LIMIT" "active_queries"
        print_colour "Number of Active Queries" "$queries/$QUERY_LIMIT"
    fi
}
function cluster_status() {
    echo_status "Patroni Status"
    if systemctl status patroni.service >/dev/null; then
        print_colour "Patroni" "Active"
        alarm_check_up "patroni" "Patroni is active again!"
    else
        print_colour "Patroni" "Active" "error"
        alarm_check_down "patroni" "Patroni is not active!"
    fi

    CLUSTER_URL="$PATRONI_API/cluster"
    if ! curl -s "$CLUSTER_URL" >/dev/null; then
        print_colour "Patroni API" "not accessible" "error"
        alarm_check_down "patroni_api" "Can't access Patroni API through: $CLUSTER_URL"
        return
    fi
    alarm_check_up "patroni_api" "Patroni API is accessible again through: $CLUSTER_URL"

    output=$(curl -s "$CLUSTER_URL")
    mapfile -t cluster_names < <(echo "$output" | jq -r '.members[] | .name ')
    mapfile -t cluster_roles < <(echo "$output" | jq -r '.members[] | .role')
    mapfile -t cluster_states < <(curl -s "$CLUSTER_URL" | jq -r '.members[] | .state')
    name=$(yq -r .name /etc/patroni/patroni.yml)
    this_node=$(curl -s "$CLUSTER_URL" | jq -r --arg name "$name" '.members[] | select(.name==$name) | .role')
    print_colour "This node" "$this_node"

    printf '\n'
    echo_status "Cluster Roles"
    i=0
    for cluster in "${cluster_names[@]}"; do
        print_colour "$cluster" "${cluster_roles[$i]}"
        if [ -f /tmp/monodb-pgsql-health/raw_output.json ]; then
            old_role="$(jq -r '.members['"$i"'] | .role' </tmp/monodb-pgsql-health/raw_output.json)"
            if [ "${cluster_roles[$i]}" != "$old_role" ] &&
                [ "$cluster" == "$(jq -r '.members['"$i"'] | .name' </tmp/monodb-pgsql-health/raw_output.json)" ]; then
                echo "  Role of $cluster has changed!"
                print_colour "  Old Role of $cluster" "$old_role" "error"
                printf '\n'
                alarm "[Patroni - $IDENTIFIER] [:info:] Role of $cluster has changed! Old: **$old_role**, Now: **${cluster_roles[$i]}**"
                if [ "${cluster_roles[$i]}" == "leader" ]; then
                    alarm "[Patroni - $IDENTIFIER] [:check:] New leader is $cluster!"
                    if [[ -n "$LEADER_SWITCH_HOOK" ]] && [[ -f "/etc/patroni/patroni.yml" ]]; then
                        if [[ "$(curl -s "$PATRONI_API" | jq -r .role)" == "master" ]]; then
                            eval "$LEADER_SWITCH_HOOK"
                            EXIT_CODE=$?
                            if [ $EXIT_CODE -eq 0 ]; then
                                alarm "[Patroni - $IDENTIFIER] [:check:] Leader switch hook executed successfully"
                            else
                                alarm "[Patroni - $IDENTIFIER] [:red_circle:] Leader switch hook failed with exit code $EXIT_CODE"
                            fi
                        fi
                    fi
                fi

            fi
        fi
        i=$((i + 1))
    done
    echo "$output" | jq >/tmp/monodb-pgsql-health/raw_output.json

    printf '\n'
    echo_status "Cluster States"
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
    echo "Monodb PostgreSQL Health $VERSION - $(date)"
    printf '\n'
    postgresql_status
    printf '\n'
    pgsql_uptime
    printf '\n'
    check_active_connections
    printf '\n'
    check_running_queries
    if [[ -n "$PATRONI_API" ]]; then
        printf '\n'
        cluster_status
    fi
}

pidfile=/var/run/monodb-pgsql-health.sh.pid
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
