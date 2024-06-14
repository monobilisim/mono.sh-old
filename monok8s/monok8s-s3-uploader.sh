#!/usr/bin/env bash
###~ description: Upload K8s resource logs to S3 bucket

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

VERSION=v0.1.0

[[ "$1" == '-v' ]] || [[ "$1" == '--version' ]] && {
    echo "$VERSION"
    exit 0
}

[[ -f "/var/lib/rancher/rke2/bin/kubectl" ]] && {
    export PATH="$PATH:/var/lib/rancher/rke2/bin"
}

mkdir -p /tmp/monok8s-s3-uploader

if [[ -f /etc/monok8s-s3-uploader.conf ]]; then
    . /etc/monok8s-s3-uploader.conf
else
    echo "Config file doesn't exists at /etc/monok8s-s3-uploader.conf"
    exit 1
fi

if [ -z "$ALARM_INTERVAL" ]; then
    ALARM_INTERVAL=3
fi

RED_FG=$(tput setaf 1)
GREEN_FG=$(tput setaf 2)
BLUE_FG=$(tput setaf 4)
RESET=$(tput sgr0)

if ! command -v aws &>/dev/null; then
    echo "AWS CLI is not installed"
    exit 1
fi

function echo_status() {
    echo "$1"
    echo ---------------------------------------------------
}

function configure_s3() {
    aws configure set aws_access_key_id "$AWS_ACCESS_KEY_ID"
    aws configure set aws_secret_access_key "$AWS_SECRET_ACCESS_KEY"
    aws configure set default.region "$AWS_DEFAULT_REGION"
}

function upload_to_s3() {
    
    configure_s3

    [ -d "/tmp/monok8s-s3-uploader/logs" ] && rm -r /tmp/monok8s-s3-uploader/logs
    mkdir -p /tmp/monok8s-s3-uploader/logs

    for resource in "${K8S_LOG_LIST[@]}"; do
        # example resource: test-namespace/pod/test-pod
        IFS='/' read -ra parts <<< "$resource"
        
        namespace=${parts[0]}
        resource_type=${parts[1]}
        resource_name=${parts[2]}
        date_day="$(date +'%Y-%m-%d')"
        date="$(date +'%Y-%m-%d-%H:%M:%S')"
        p="/tmp/monok8s-s3-uploader/logs/$namespace/$resource_type/$resource_name/$date-$resource_name.log"
        mkdir -p "/tmp/monok8s-s3-uploader/logs/$namespace/$resource_type/$resource_name"
        kubectl logs -n "$namespace" "$resource_type/$resource_name" &>$p
        
        if [ "$?" -ne 0 ]; then
            print_colour "$resource_name" "failed to get" "error"
            alarm_check_down "$resource_name" "Failed to get logs"
        else
            print_colour "$resource" "logs fetched"
            alarm_check_up "$resource_name" "Logs fetched"
        fi
        
        if [[ -n "$AWS_ENDPOINT_URL" ]]; then
            if aws s3 cp --quiet "$p" "s3://$S3_BUCKET/monok8s-logs/$date_day/$namespace/$resource_type/$resource_name/$date-$resource_name.log" --endpoint-url "$AWS_ENDPOINT_URL" 2>/dev/null; then
                print_colour "$resource" "uploaded"
                alarm_check_up "$resource" "Logs uploaded"
            else
                print_colour "$resource" "failed to upload" "error"
                alarm_check_down "$resource" "Failed to upload logs for namespace '$namespace', resource type '$resource_type' and resource name '$resource_name'"
            fi 
        else
            if aws s3 cp --quiet "$p" "s3://$S3_BUCKET/monok8s-logs/$date_day/$namespace/$resource_type/$resource_name/$date-$resource_name.log" 2>/dev/null; then
                print_colour "$resource" "uploaded"
                alarm_check_up "$resource" "Logs uploaded"
            else
                print_colour "$resource" "failed to upload" "error"
                alarm_check_down "$resource" "Failed to upload logs for namespace '$namespace', resource type '$resource_type' and resource name '$resource_name'"
            fi 
        fi
    done
}

function print_colour() {
    if [ "$3" != 'error' ]; then
        printf "  %-40s %s\n" "${BLUE_FG}$1${RESET}" "${GREEN_FG}$2${RESET}"
    else
        printf "  %-40s %s\n" "${BLUE_FG}$1${RESET}" "${RED_FG}$2${RESET}"
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
    file_path="/tmp/monok8s-s3-uploader/script_${service_name}_status.txt"

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
    file_path="/tmp/monok8s-s3-uploader/script_${service_name}_status.txt"

    if [ -z $3 ]; then
        if [ -f "${file_path}" ]; then
            old_date=$(awk '{print $1}' <"$file_path")
            current_date=$(date "+%Y-%m-%d")
            if [ "${old_date}" != "${current_date}" ]; then
                date "+%Y-%m-%d %H:%M" >"${file_path}"
                alarm "[monok8s-s3-uploader - $IDENTIFIER] [:red_circle:] $2"
            fi
        else
            date "+%Y-%m-%d %H:%M" >"${file_path}"
            alarm "[monok8s-s3-uploader - $IDENTIFIER] [:red_circle:] $2"
        fi
    else
        if [ -f "${file_path}" ]; then
            old_date=$(awk '{print $1}' <"$file_path")
            [[ -z $(awk '{print $3}' <"$file_path") ]] && locked=false || locked=true
            current_date=$(date "+%Y-%m-%d")
            if [ "${old_date}" != "${current_date}" ]; then
                date "+%Y-%m-%d %H:%M locked" >"${file_path}"
                alarm "[monok8s-s3-uploader - $IDENTIFIER] [:red_circle:] $2"
            else
                if ! $locked; then
                    time_diff=$(get_time_diff "$1")
                    if ((time_diff >= ALARM_INTERVAL)); then
                        date "+%Y-%m-%d %H:%M locked" >"${file_path}"
                        alarm "[monok8s-s3-uploader - $IDENTIFIER] [:red_circle:] $2"
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
    file_path="/tmp/monok8s-s3-uploader/script_${service_name}_status.txt"

    # delete_time_diff "$1"
    if [ -f "${file_path}" ]; then

        if [ -z $3 ]; then
            rm -rf "${file_path}"
            alarm "[monok8s-s3-uploader - $IDENTIFIER] [:check:] $2"
        else
            [[ -z $(awk '{print $3}' <"$file_path") ]] && locked=false || locked=true
            rm -rf "${file_path}"
            if $locked; then
                alarm "[monok8s-s3-uploader - $IDENTIFIER] [:check:] $2"
            fi
        fi
    fi
}


function main() {
    printf '\n'
    echo "MonoK8s S3 Uploader $VERSION - $(date)"
    printf '\n'
    upload_to_s3
}

pidfile=/var/run/monok8s-s3-uploader.sh.pid
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
