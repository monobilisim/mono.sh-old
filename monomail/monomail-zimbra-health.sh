#!/bin/bash
###~ description: This script checks zimbra and zextras health

VERSION=v0.8.0

[[ "$1" == '-v' ]] || [[ "$1" == '--version' ]] && {
    echo "$VERSION"
    exit 0
}

mkdir -p /tmp/monomail-zimbra-health

if [[ -f /etc/monomail-zimbra-health.conf ]]; then
    . /etc/monomail-zimbra-health.conf
else
    echo "Config file doesn't exists at /etc/monomail-zimbra-health.conf"
    exit 1
fi

if [ -z "$ALARM_INTERVAL" ]; then
    ALARM_INTERVAL=5
fi

RED_FG=$(tput setaf 1)
GREEN_FG=$(tput setaf 2)
BLUE_FG=$(tput setaf 4)
RESET=$(tput sgr0)

RESTART_COUNTER=0

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

function get_time_diff() {
    [[ -z $1 ]] && {
        echo "Service name is not defined"
        return
    }
    service_name=$1
    service_name=$(echo "$service_name" | sed 's#/#-#g')
    file_path="/tmp/monomail-zimbra-health/postal_${service_name}_status.txt"

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
    service_name=${1//\//-}
    file_path="/tmp/monomail-zimbra-health/postal_${service_name}_status.txt"

    if [ -z $3 ]; then
        if [ -f "${file_path}" ]; then
            old_date=$(awk '{print $1}' <"$file_path")
            current_date=$(date "+%Y-%m-%d")
            if [ "${old_date}" != "${current_date}" ]; then
                date "+%Y-%m-%d %H:%M" >"${file_path}"
                alarm "[Zimbra - $IDENTIFIER] [:red_circle:] $2"
            fi
        else
            date "+%Y-%m-%d %H:%M" >"${file_path}"
            alarm "[Zimbra - $IDENTIFIER] [:red_circle:] $2"
        fi
    else
        if [ -f "${file_path}" ]; then
            old_date=$(awk '{print $1}' <"$file_path")
            [[ -z $(awk '{print $3}' <"$file_path") ]] && locked=false || locked=true
            current_date=$(date "+%Y-%m-%d")
            if [ "${old_date}" != "${current_date}" ]; then
                date "+%Y-%m-%d %H:%M locked" >"${file_path}"
                alarm "[Zimbra - $IDENTIFIER] [:red_circle:] $2"
            else
                if ! $locked; then
                    time_diff=$(get_time_diff "$1")
                    if ((time_diff >= ALARM_INTERVAL)); then
                        date "+%Y-%m-%d %H:%M locked" >"${file_path}"
                        alarm "[Zimbra - $IDENTIFIER] [:red_circle:] $2"
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
    file_path="/tmp/monomail-zimbra-health/postal_${service_name}_status.txt"

    # delete_time_diff "$1"
    if [ -f "${file_path}" ]; then

        if [ -z $3 ]; then
            rm -rf "${file_path}"
            alarm "[Zimbra - $IDENTIFIER] [:check:] $2"
        else
            [[ -z $(awk '{print $3}' <"$file_path") ]] && locked=false || locked=true
            rm -rf "${file_path}"
            if $locked; then
                alarm "[Zimbra - $IDENTIFIER] [:check:] $2"
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

ZIMBRA_SERVICES=(
    "amavis:zmamavisdctl"
    "antispam:zmamavisdctl"
    "antivirus:zmclamdctl:zmfreshclamctl"
    "cbpolicyd:zmcbpolicydctl"
    "dnscache:zmdnscachectl"
    "ldap:ldap"
    "logger:zmloggerctl"
    "mailbox:zmmailboxdctl"
    "memcached:zmmemcachedctl"
    "mta:zmmtactl:zmsaslauthdctl"
    "opendkim:zmopendkimctl"
    "proxy:zmproxyctl"
    "service webapp:zmmailboxdctl"
    "snmp:zmswatch"
    "spell:zmspellctl:zmapachectl"
    "stats:zmstatctl"
    "zimbra webapp:zmmailboxdctl"
    "zimbraAdmin webapp:zmmailboxdctl"
    "zimlet webapp:zmmailboxdctl"
    "zmconfigd:zmconfigdctl"
)
for i in "${ZIMBRA_SERVICES[@]}"; do
    zimbra_service_name=$(echo $i | cut -d \: -f1)
    zimbra_service_ctl=($(echo $i | cut -d\: -f2- | sed 's/:/ /g'))
done

function check_ip_access() {
    echo_status "Access through IP"
    [[ -d "/opt/zimbra" ]] && {
        ZIMBRA_PATH='/opt/zimbra'
        PRODUCT_NAME='zimbra'
    }
    [[ -d "/opt/zextras" ]] && {
        ZIMBRA_PATH='/opt/zextras'
        PRODUCT_NAME='carbonio'
    }
    [[ ! -n $ZIMBRA_PATH ]] && {
        echo "Zimbra not found in /opt, aborting..."
        exit 1
    }

    #~ define variables
    templatefile="$ZIMBRA_PATH/conf/nginx/templates/nginx.conf.web.https.default.template"
    certfile="$ZIMBRA_PATH/ssl/$PRODUCT_NAME/server/server.crt"
    keyfile="$ZIMBRA_PATH/ssl/$PRODUCT_NAME/server/server.key"
    message="Hello World!"

    #~ check template file and ip
    [[ ! -e $templatefile ]] && {
        echo "File \"$templatefile\" not found, aborting..."
        exit 1
    }
    [[ -e "$ZIMBRA_PATH/conf/nginx/external_ip.txt" ]] && ipaddress="$(cat $ZIMBRA_PATH/conf/nginx/external_ip.txt)" || ipaddress="$(curl -fsSL ifconfig.co)"
    [[ ! -n "$(echo $ipaddress | grep -Pzi '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tr '\0' '\n')" ]] && {
        echo "IP address error, aborting..."
        exit 1
    }

    #~ define regex pattern and proxy block
    regexpattern="\\n?(server\\s+?{\\n?\\s+listen\\s+443\\sssl\\shttp2;\\n?\\s+server_name\\n?\\s+$ipaddress;\\n?\\s+ssl_certificate\\s+$certfile;\\n?\\s+ssl_certificate_key\\s+$keyfile;\\n?\\s+location\\s+\\/\\s+{\\n?\\s+return\\s200\\s\'$message\';\\n?\\s+}\\n?})"
    proxyblock="
server {
        listen                  443 ssl http2;
        server_name             $ipaddress;
        ssl_certificate         $certfile;
        ssl_certificate_key     $keyfile;
        location / {
                return 200 '$message';
        }
}"

    #~ check block from templatefile
    if [[ -z $(grep -Pzio "$regexpattern" $templatefile | tr '\0' '\n') ]]; then
        echo "Adding proxy control block in $templatefile file..."
        echo -e "$proxyblock" >>$templatefile
        echo "Added proxy control block in $templatefile file..."
    fi
    ip=$(wget -qO- ifconfig.me/ip)
    if ! curl -s --insecure --connect-timeout 15 https://"$ip" | grep -iq zimbra; then
        alarm_check_up "ip_access" "Can't access to zimbra through plain ip: $ip"
        print_colour "Access with ip" "not accessible"
    else
        alarm_check_down "ip_access" "Can access to zimbra through plain ip: $ip"
        print_colour "Access with ip" "accessible" "error"
    fi
}

function check_zimbra_services() {
    echo_status "Zimbra services"
    OLDIFS=$IFS
    IFS=$'\n'
    if id "zimbra" &>/dev/null; then
        zimbra_services="$(su - zimbra -c "zmcontrol status" 2>/dev/null | sed '1d')"
    else
        zimbra_services="$(su - zextras -c "zmcontrol status" 2>/dev/null | sed '1d')"
    fi
    # should_restart=0
    i=0
    for service in $zimbra_services; do
        i=$((i + 1))
        is_active=$(echo "$service" | awk '{print $NF}')
        service_name=$(echo "$service" | awk '{NF--; print}')
        if [[ $is_active =~ [A-Z] ]]; then
            if [ "${is_active,,}" != 'running' ]; then
                [ $RESTART_COUNTER -gt $RESTART_LIMIT ] && {
                    alarm_check_down "$service_name" "Couldn't restart stopped services in $((RESTART_LIMIT + 1)) tries" "service"
                    echo "${RED_FG}Couldn't restart stopped services in $((RESTART_LIMIT + 1)) tries${RESET}"
                    return
                }
                print_colour "$service_name" "$is_active" "error"
                alarm_check_down "$service_name" "Service: $service_name is not running" "service"
                if [ $RESTART == 1 ]; then
                    # i=$(echo "${ZIMBRA_SERVICES[@]}" | sed 's/ /\n/g' | grep "$service_name:")
                    # zimbra_service_name=$(echo $i | cut -d \: -f1)
                    # zimbra_service_ctl=($(echo $i | cut -d\: -f2- | sed 's/:/\n/g'))
                    # for ctl in "${zimbra_service_ctl[@]}"; do
                    #     echo Restarting "$ctl"...
                    #     su - zimbra -c "$ctl start"
                    #     if ! su - zimbra -c "$ctl start"; then
                    #         RESTART_COUNTER=$((RESTART_COUNTER + 1))
                    #     fi
                    # done
                    # printf '\n'
                    # check_zimbra_services
                    # break

                    if ! su - zimbra -c "zmcontrol start"; then
                        RESTART_COUNTER=$((RESTART_COUNTER + 1))
                    fi
                    printf '\n'
                    check_zimbra_services
                    break

                    # should_continue=true
                    # while $should_continue; do
                    #     if [[ $(echo "${zimbra_services[i]}" | awk '{print $NF}') =~ [A-Z] ]]; then
                    #         should_continue=false
                    #     else
                    #         ctl=$(echo "${zimbra_services[i]}" | awk '{print $1}')
                    #         su - zimbra -c "$ctl start"
                    #         RESTART_COUNTER
                    #         i=$((i + 1))
                    #     fi
                    # done
                fi
                # should_restart=1
            else
                print_colour "$service_name" "$is_active"
                alarm_check_up "$service_name" "Service: $service_name started running" "service"
            fi
        fi
    done
    IFS=$OLDIFS
}

function check_z-push() {
    echo_status "Checking Z-Push:"
    if curl -Isk "$Z_URL" | grep -i zpush >/dev/null; then
        alarm_check_up "z-push" "Z-Push started working"
        print_colour "Z-Push" "Working"
    else
        alarm_check_down "z-push" "Z-Push is not working"
        print_colour "Z-Push" "Not Working" "error"
    fi
}

function queued_messages() {
    echo_status "Queued Messages"
    if [ -d /opt/zimbra ]; then
        queue=$(/opt/zimbra/common/sbin/mailq | grep -c "^[A-F0-9]")
    else
        queue=$(/opt/zextras/common/sbin/mailq | grep -c "^[A-F0-9]")
    fi
    if [ "$queue" == "$QUEUE_LIMIT" ]; then
        print_colour "Number of queued messages" "$queue"
        alarm_check_up "queued" "Number of queued messages is acceptable - $queue/$QUEUE_LIMIT" "queue"
    else
        print_colour "Number of queued messages" "$queue" "error"
        alarm_check_down "queued" "Number of queued messages is above limit - $queue/$QUEUE_LIMIT" "queue"
    fi
}

function main() {
    printf '\n'
    echo "Monomail Zimbra Health $VERSION - $(date)"
    printf '\n'
    check_ip_access
    printf '\n'
    check_zimbra_services
    printf '\n'
    check_z-push
    printf '\n'
    queued_messages

    rm -rf /tmp/monomail-zimbra-health/postal_session_*_status.txt
}

pidfile=/var/run/monomail-zimbra-health.sh.pid
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
