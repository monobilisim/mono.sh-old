#!/usr/bin/env bash
###~ description: Check the status of WPPConnect sessions

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

VERSION=v0.2.0

[[ "$1" == '-v' ]] || [[ "$1" == '--version' ]] && {
    echo "$VERSION"
    exit 0
}

mkdir -p /tmp/monocloud-wppconnect

if [[ -f /etc/monocloud-wppconnect-health.conf ]]; then
    . /etc/monocloud-wppconnect-health.conf
else
    echo "Config file doesn't exists at /etc/monocloud-wppconnect-health.conf"
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
    service_name=${1//\//-}
    file_path="/tmp/monocloud-wppconnect/monocloud-wppconnect_${service_name}_status.txt"

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
    file_path="/tmp/monocloud-wppconnect/monocloud-wppconnect_${service_name}_status.txt"

    if [ -z $3 ]; then
        if [ -f "${file_path}" ]; then
            old_date=$(awk '{print $1}' <"$file_path")
            current_date=$(date "+%Y-%m-%d")
            if [ "${old_date}" != "${current_date}" ]; then
                date "+%Y-%m-%d %H:%M" >"${file_path}"
                alarm "[Mono Cloud WPPConnect - $IDENTIFIER] [:red_circle:] $2"
            fi
        else
            date "+%Y-%m-%d %H:%M" >"${file_path}"
            alarm "[Mono Cloud WPPConnect - $IDENTIFIER] [:red_circle:] $2"
        fi
    else
        if [ -f "${file_path}" ]; then
            old_date=$(awk '{print $1}' <"$file_path")
            [[ -z $(awk '{print $3}' <"$file_path") ]] && locked=false || locked=true
            current_date=$(date "+%Y-%m-%d")
            if [ "${old_date}" != "${current_date}" ]; then
                date "+%Y-%m-%d %H:%M locked" >"${file_path}"
                alarm "[Mono Cloud WPPConnect - $IDENTIFIER] [:red_circle:] $2"
            else
                if ! $locked; then
                    time_diff=$(get_time_diff "$1")
                    if ((time_diff >= ALARM_INTERVAL)); then
                        date "+%Y-%m-%d %H:%M locked" >"${file_path}"
                        alarm "[Mono Cloud WPPConnect - $IDENTIFIER] [:red_circle:] $2"
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
    service_name=${1//\//-}
    file_path="/tmp/monocloud-wppconnect/monocloud-wppconnect_${service_name}_status.txt"

    # delete_time_diff "$1"
    if [ -f "${file_path}" ]; then

        if [ -z $3 ]; then
            rm -rf "${file_path}"
            alarm "[Mono Cloud WPPConnect - $IDENTIFIER] [:check:] $2"
        else
            [[ -z $(awk '{print $3}' <"$file_path") ]] && locked=false || locked=true
            rm -rf "${file_path}"
            if $locked; then
                alarm "[Mono Cloud WPPConnect - $IDENTIFIER] [:check:] $2"
            fi
        fi
    fi
}

function wpp_check() {
    curl -fsSL -X GET --location "$WPP_URL/api/$WPP_SECRET/show-all-sessions" \
	-H "Accept: application/json" \
	-H "Content-Type: application/json" | jq -c -r '.response[]' | while read -r SESSION; do
	TOKEN="$(curl -fsSL -X POST --location "$WPP_URL/api/$SESSION/$WPP_SECRET/generate-token" | jq -r '.token')"
	STATUS="$(curl -fsSL -X GET --location "$WPP_URL/api/$SESSION/check-connection-session" \
	    -H "Accept: application/json" \
	    -H "Content-Type: application/json" \
	    -H "Authorization: Bearer $TOKEN" | jq -c -r '.message')"
	CONTACT_NAME="$(curl -fsSL -X GET --location "$WPP_URL/api/$SESSION/contact/$SESSION" \
	    -H "Accept: application/json" \
	    -H "Content-Type: application/json" \
	    -H "Authorization: Bearer $TOKEN" | jq -c -r '.response.name // .response.pushname // "No Name"')"

	if [[ "$STATUS" == "Connected" ]]; then
	    print_colour "$CONTACT_NAME, Session $SESSION" "$STATUS"
	    alarm_check_up "wpp_session_$SESSION" "Session $SESSION with name $CONTACT_NAME is connected again" "$ALARM_INTERVAL"
	else
	   alarm_check_down "wpp_session_$SESSION" "Session $SESSION with name $CONTACT_NAME is not connected, status '$STATUS'" "$ALARM_INTERVAL"
	    print_colour "$CONTACT_NAME, Session $SESSION" "$STATUS" "error"
	fi
    done
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

function main() {
    printf '\n'
    echo "Mono Cloud WPPConnect $VERSION - $(date)"
    printf '\n'
    wpp_check
}

pidfile=/var/run/monocloud-wppconnect.sh.pid
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
