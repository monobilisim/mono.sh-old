#!/bin/bash
###~ description: Checks the status of postal and related services

VERSION=v1.0.3

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[[ "$1" == '-v' ]] || [[ "$1" == '--version' ]] && {
    echo "$VERSION"
    exit 0
}

mkdir -p /tmp/monomail-postal-health

if [[ -f /etc/monomail-postal-health.conf ]]; then
    . /etc/monomail-postal-health.conf
else
    echo "Config file doesn't exists at /etc/monomail-postal-health.conf"
    exit 1
fi

# https://github.com/mikefarah/yq v4.40.5 sürümü ile test edilmiştir
if [ -z "$(command -v yq)" ]; then
    read -p "Couldn't find github.com/mikefarah/yq Want me to download and put it under /usr/local/bin? [y/n]: " yn
    case $yn in
    [Yy]*)
        wget -O /usr/local/bin/yq https://github.com/mikefarah/yq/releases/download/v4.40.5/yq_linux_amd64
        chmod +x /usr/local/bin/yq
        ;;
    [Nn]*)
        echo "Aborted"
        exit 1
        ;;
    esac
fi

if [ -z "$ALARM_INTERVAL" ]; then
    ALARM_INTERVAL=5
fi

RED_FG=$(tput setaf 1)
GREEN_FG=$(tput setaf 2)
BLUE_FG=$(tput setaf 4)
RESET=$(tput sgr0)

if [ "$1" == "test" ]; then postal_config="./test.yaml"; else postal_config=/opt/postal/config/postal.yml; fi


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
    file_path="/tmp/monomail-postal-health/postal_${service_name}_status.txt"

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

function alarm_check_down() {
    [[ -z $1 ]] && {
        echo "Service name is not defined"
        return
    }
    service_name=$1
    service_name=$(echo "$service_name" | sed 's#/#-#g')
    file_path="/tmp/monomail-postal-health/postal_${service_name}_status.txt"

    if [ -z $3 ]; then
        if [ -f "${file_path}" ]; then
            old_date=$(awk '{print $1}' <"$file_path")
            current_date=$(date "+%Y-%m-%d")
            if [ "${old_date}" != "${current_date}" ]; then
                date "+%Y-%m-%d %H:%M" >"${file_path}"
                alarm "[Postal - $IDENTIFIER] [:red_circle:] $2"
            fi
        else
            date "+%Y-%m-%d %H:%M" >"${file_path}"
            alarm "[Postal - $IDENTIFIER] [:red_circle:] $2"
        fi
    else
        if [ -f "${file_path}" ]; then
            old_date=$(awk '{print $1}' <"$file_path")
            [[ -z $(awk '{print $3}' <"$file_path") ]] && locked=false || locked=true
            current_date=$(date "+%Y-%m-%d")
            if [ "${old_date}" != "${current_date}" ]; then
                date "+%Y-%m-%d %H:%M locked" >"${file_path}"
                alarm "[Postal - $IDENTIFIER] [:red_circle:] $2"
            else
                if ! $locked; then
                    time_diff=$(get_time_diff "$1")
                    if ((time_diff >= ALARM_INTERVAL)); then
                        date "+%Y-%m-%d %H:%M locked" >"${file_path}"
                        alarm "[Postal - $IDENTIFIER] [:red_circle:] $2"
                        if [ $3 == "service" ] || [ $3 == "queue" ]; then
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
    service_name=$1
    service_name=$(echo "$service_name" | sed 's#/#-#g')
    file_path="/tmp/monomail-postal-health/postal_${service_name}_status.txt"

    # delete_time_diff "$1"
    if [ -f "${file_path}" ]; then

        if [ -z $3 ]; then
            rm -rf "${file_path}"
            alarm "[Postal - $IDENTIFIER] [:check:] $2"
        else
            [[ -z $(awk '{print $3}' <"$file_path") ]] && locked=false || locked=true
            rm -rf "${file_path}"
            if $locked; then
                alarm "[Postal - $IDENTIFIER] [:check:] $2"
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

if [ -z "$(command -v mysql)" ]; then
    echo "Couldn't find mysql on the server - Aborting"
    alarm_check_down "mysql" "Can't find mysql on $IDENTIFIER - Aborting"
    exit 1
fi
alarm_check_up "mysql" "Found mysql on $IDENTIFIER"
# ------- MySQL main_db stats -------
main_db_host=$(yq -r .main_db.host $postal_config)
main_db_port=$(yq -r .main_db.port $postal_config)
if [ "$main_db_port" = "null" ]; then
    main_db_port="3306"
fi
main_db_user=$(yq -r .main_db.username $postal_config)
main_db_pass=$(yq -r .main_db.password $postal_config)
if ! main_db_status=$(mysqladmin -h"$main_db_host" -P"$main_db_port" -u"$main_db_user" -p"$main_db_pass" ping 2>&1); then
    alarm_check_down "maindb" "Can't connect to main_db at host $main_db_host with the parameters on $postal_config at $IDENTIFIER"
else
    alarm_check_up "maindb" "Able to connect main_db at host $main_db_host at $IDENTIFIER"
fi

# ------- MySQL message_db stats -------
message_db_host=$(yq -r .message_db.host $postal_config)
message_db_port=$(yq -r .message_db.port $postal_config)
if [ "$message_db_port" = "null" ]; then
    message_db_port="3306"
fi
message_db_user=$(yq -r .message_db.username $postal_config)
message_db_pass=$(yq -r .message_db.password $postal_config)
if ! message_db_status=$(mysqladmin -h"$message_db_host" -P"$message_db_port" -u"$message_db_user" -p"$message_db_pass" ping 2>&1); then
    alarm_check_down "messagedb" "Can't connect to messagedb at host $message_db_host with the parameters on $postal_config at $IDENTIFIER"
else
    alarm_check_up "messagedb" "Able to connect messagedb at host $message_db_host at $IDENTIFIER"
fi

function echo_status() {
    echo "$1"
    echo ---------------------------------------------------
}

fnServices() {
    if systemctl status postal >/dev/null; then
        if [ -z "$(command -v docker)" ]; then
            echo "Couldn't find docker on the server - Aborting"
            alarm_check_down "docker" "Can't find docker on $IDENTIFIER - Aborting"
            exit 1
        fi
        alarm_check_up "postal" "Postal is running again at $IDENTIFIER"
        alarm_check_up "docker" "Docker found at $IDENTIFIER"
        echo_status "Postal status:"
        postal_status=$(docker ps --format "table {{.Names}} {{.Status}}" | grep postal)
        if [ -z "$postal_status" ]; then
            alarm_check_down "postal" "Couldn't find any postal services at $IDENTIFIER. Postal might have been stopped. Please check!"
            echo "  Couldn't find any postal services. Postal might have been stopped. Please check!"
        else
            postal_services=$(echo "$postal_status" | awk '{print $1}')

            for service in $postal_services; do
                service_status=$(echo "$postal_status" | grep "$service" | awk '{print substr($0, index($0,$2))}')
                if [ "$(echo "$service_status" | awk '{print $1}')" == "Up" ]; then
                    alarm_check_up "$service" "Postal service $service is $service_status at $IDENTIFIER"
                    printf "  %-40s %s\n" "${BLUE_FG}$service${RESET}" "is ${GREEN_FG}$service_status${RESET}"
                else
                    alarm_check_down "$service" "Postal service $service is $service_status at $IDENTIFIER"
                    printf "  %-40s %s\n" "${BLUE_FG}$service${RESET}" "is ${RED_FG}$service_status${RESET}"
                fi
            done
        fi
    else
        echo_status "Postal status:"
        alarm_check_down "postal" "Postal is not running at $IDENTIFIER"
        printf "  %-40s %s\n" "${BLUE_FG}Postal${RESET}" "is ${RED_FG}not running${RESET}"
    fi
}

fnMySQL() {
    echo_status "MySQL status:"
    if [ "$main_db_status" = "mysqld is alive" ]; then
        alarm_check_up "maindb" "MySQL main_db: $main_db_status at $IDENTIFIER"
        printf "  %-40s %s\n" "${BLUE_FG}main_db${RESET}" "${GREEN_FG}$main_db_status${RESET}"
    else
        alarm_check_down "maindb" "MySQL main_db: $main_db_status at $IDENTIFIER"
        printf "  %-40s %s\n" "${BLUE_FG}main_db${RESET}" "${RED_FG}$main_db_status${RESET}"
    fi
    if [ "$message_db_status" = "mysqld is alive" ]; then
        alarm_check_up "messagedb" "MySQL message_db: $message_db_status at $IDENTIFIER"
        printf "  %-40s %s\n" "${BLUE_FG}message_db${RESET}" "${GREEN_FG}$message_db_status${RESET}"
    else
        alarm_check_down "messagedb" "MySQL message_db: $message_db_status at $IDENTIFIER"
        printf "  %-40s %s\n" "${BLUE_FG}message_db${RESET}" "${RED_FG}$message_db_status${RESET}"
    fi
}
fnMessageQueue() {
    if ! db_message_queue=$(mysql -h"$message_db_host" -P"$message_db_port" -u"$message_db_user" -p"$message_db_pass" -sNe "select count(*) from postal.queued_messages;" 2>&1); then
        alarm_check_down "status_db_message_queue" "Couldn't retrieve message queue information from message_db at host $message_db_host with the parameters on $postal_config at $IDENTIFIER" "queue"
        db_message_queue_error="$db_message_queue"
        db_message_queue=-1
    else
        alarm_check_up "status_db_message_queue" "Able to retrieve message queue information from message_db at host $message_db_host at $IDENTIFIER" "queue"
    fi
    echo_status "Message Queue:"
    if [ "$db_message_queue" -lt $message_threshold ] && ! [ "$db_message_queue" -lt 0 ]; then
        alarm_check_up "db_message_queue" "Number of queued messages is back to normal - $db_message_queue/$message_threshold at $IDENTIFIER" "queue"
        printf "  %-40s %s\n" "${BLUE_FG}Queued messages${RESET}" "are smaller than ${GREEN_FG}$message_threshold - Queue: $db_message_queue${RESET}"
    elif [ "$db_message_queue" -eq -1 ]; then
        printf "  %-40s %s\n" "${BLUE_FG}Queued messages${RESET}" "${RED_FG}$db_message_queue_error${RESET}"
    else
        alarm_check_down "db_message_queue" "Number of queued messages is above threshold - $db_message_queue/$message_threshold at $IDENTIFIER" "queue"
        printf "  %-40s %s\n" "${BLUE_FG}Queued messages${RESET}" "are greater than ${RED_FG}$message_threshold - Queue: $db_message_queue${RESET}"
    fi
}

fnMessageHeld() {
    echo_status "Held Messages:"
    postal_servers=("$(mysql -h"$message_db_host" -P"$message_db_port" -u"$message_db_user" -p"$message_db_pass" -sNe "select id from postal.servers;" | sort -n)")
    for i in ${postal_servers[@]}; do
        variable="postal-server-$i"
        if ! db_message_held=$(mysql -h"$message_db_host" -P"$message_db_port" -u"$message_db_user" -p"$message_db_pass" -sNe "USE $variable; SELECT COUNT(id) FROM messages WHERE status = 'Held';" 2>&1); then
            alarm_check_down "status_$variable" "Couldn't retrieve information of held messages for $variable from message_db at host $message_db_host with the parameters on $postal_config at $IDENTIFIER"
            db_message_held_error="$db_message_held"
            db_message_held=-1
        else
            alarm_check_up "status_$variable" "Able to retrieve information of held messages for $variable from message_db at host $message_db_host at $IDENTIFIER"
        fi
        if [ "$db_message_held" -lt "$held_threshold" ] && ! [ "$db_message_held" -lt 0 ]; then
            alarm_check_up "$variable" "Number of Held messages of $variable is back to normal - $db_message_held/$held_threshold at $IDENTIFIER"
            printf "  %-40s %s\n" "${BLUE_FG}$variable${RESET}" "Held messages are smaller than ${GREEN_FG}$held_threshold - Held: $db_message_held${RESET}"
        elif [ "$db_message_held" -eq -1 ]; then
            printf "  %-40s %s\n" "${BLUE_FG}$variable${RESET}" "Held messages ${RED_FG}$db_message_held_error${RESET}"
        else-
            alarm_check_down "$variable" "Number of Held messages of $variable is above threshold - $db_message_held/$held_threshold at $IDENTIFIER"
            printf "  %-40s %s\n" "${BLUE_FG}$variable${RESET}" "Held messages are greater than ${RED_FG}$held_threshold - Held: $db_message_held${RESET}"
        fi
    done
}

main() {
    fnServices
    printf '\n'
    fnMySQL
    printf '\n'
    if [ "$CHECK_MESSAGE" == "1" ]; then
        fnMessageQueue
        printf '\n'
        fnMessageHeld
        printf '\n'
    fi
}

pidfile=/var/run/monomail-postal-health.sh.pid
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
