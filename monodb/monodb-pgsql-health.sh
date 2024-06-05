#!/usr/bin/env bash
###~ description: Checks the status of PostgreSQL and Patroni cluster
VERSION=v0.9.1

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
                        if [ $3 == "service" ]; then
                            check_active_sessions
                        fi
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

function check_active_sessions() {
    active_sessions=($(ls /var/run/ssh-session))
    if [[ ${#active_sessions[@]} == 0 ]]; then
        return
    else
        for session in "${active_sessions[@]}"; do
            user=$(jq -r .username /var/run/ssh-session/"$session")
            alarm_check_down "session_$session" "User *$user* is connected to host"
        done
    fi
}

function postgresql_status() {
    echo_status "PostgreSQL Status"
    if systemctl status postgresql.service >/dev/null || systemctl status postgresql*.service >/dev/null; then
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
        uptime="$(eval $command | awk 'NR==3')"
        alarm_check_up "now" "Can run 'SELECT' statements again"
        print_colour "Uptime" "$uptime"
    else
        alarm_check_down "now" "Couldn't run a 'SELECT' statement on PostgreSQL"
        print_colour "Uptime" "not accessible" "error"
        exit 1
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
    output=$(curl -s "$PATRONI_API")
    mapfile -t cluster_names < <(echo "$output" | jq -r '.members[] | .name ')
    mapfile -t cluster_roles < <(echo "$output" | jq -r '.members[] | .role')
    i=0
    for cluster in "${cluster_names[@]}"; do
        print_colour "$cluster" "${cluster_roles[$i]}"
        if
            [ -f /tmp/monodb-pgsql-health/raw_output.json ]
        then
            old_role="$(jq -r '.members['"$i"'] | .role' </tmp/monodb-pgsql-health/raw_output.json)"
            if [ "${cluster_roles[$i]}" != "$old_role" ] &&
                [ "$cluster" == "$(jq -r '.members['"$i"'] | .name' </tmp/monodb-pgsql-health/raw_output.json)" ]; then
                echo "  Role of $cluster has changed!"
                print_colour "  Old Role of $cluster" "$old_role" "error"
                printf '\n'
                alarm "[Patroni - $IDENTIFIER] [:info:] Role of $cluster has changed! Old: **$old_role**, Now: **${cluster_roles[$i]}**"
                if [ "${cluster_roles[$i]}" == "leader" ]; then
                    alarm "[Patroni - $IDENTIFIER] [:check:] New leader is $cluster!"
                    if [[ -n "$LEADER_SWITCH_HOOK" ]]; then
                        eval "$LEADER_SWITCH_HOOK"
                        if [ $? -eq 0 ]; then
                            alarm "[Patroni - $IDENTIFIER] [:check:] Leader switch hook executed successfully"
                        else
                            alarm "[Patroni - $IDENTIFIER] [:red_circle:] Leader switch hook failed"
                        fi
                    fi
                fi

            fi
        fi
        i=$((i + 1))
    done
    echo "$output" | jq >/tmp/monodb-pgsql-health/raw_output.json
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
    echo "Monodb PostgreSQL Health $VERSION - $(date)"
    printf '\n'
    postgresql_status
    printf '\n'
    pgsql_uptime
    if [[ -n "$PATRONI_API" ]]; then
        printf '\n'
        patroni_status
        printf '\n'
        cluster_role
        printf '\n'
        cluster_state
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
