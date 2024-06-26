#!/usr/bin/env bash
###~ description: Common functions for all scripts

#shellcheck disable=SC2034

if [[ -f /etc/mono.sh/main.yaml ]]; then
    CONFIG_PATH_COMMON="/etc/mono.sh/main.yaml"
elif [[ -f /etc/mono.sh/main.yml ]]; then
    CONFIG_PATH_COMMON="/etc/mono.sh/main.yml"
elif [[ -z $CONFIG_PATH_COMMON ]]; then
    echo "common.sh: Config file not found"
    exit 1
fi

function yaml() {
    OUTPUT=$(yq "$1" $CONFIG_PATH_COMMON)

    case $OUTPUT in
        null)
            if [[ -z $2 ]]; then
                echo "''"
            else
                echo "$2"
            fi
            ;;
        true)
            echo "1"
            ;;
        false)
            echo "0"
            ;;
        *)
            echo "$OUTPUT"
            ;;
    esac
}

function parse_common() {
    # Alarm
    readarray -t ALARM_WEBHOOK_URLS < <(yaml .alarm.webhook_urls[])
    IDENTIFIER="$(yaml .identifier)"
    SEND_ALARM="$(yaml '.send_alarm' 1)"

    ## Bot
    SEND_DM_ALARM="$(yaml '.alarm.bot.enabled' 0)"
    ALARM_BOT_API_URL="$(yaml .alarm.bot.alarm_url)"
    ALARM_BOT_EMAIL="$(yaml .alarm.bot.email)"
    ALARM_BOT_API_KEY="$(yaml .alarm.bot.api_key)"
    readarray -t ALARM_BOT_USER_EMAILS < <(yaml .alarm.bot.user_emails[])

    ## Redmine (WIP)
    REDMINE_API_KEY="$(yaml .redmine.api_key)"
    REDMINE_URL="$(yaml .redmine.url)"
    REDMINE_ENABLE="$(yaml '.redmine.enabled' 1)"
    REDMINE_PROJECT_ID="$(yaml .redmine.project_id)"
    REDMINE_TRACKER_ID="$(yaml .redmine.tracker_id)"
    REDMINE_PRIORITY_ID="$(yaml .redmine.priority_id)"
    REDMINE_STATUS_ID="$(yaml .redmine.status_id)"
    REDMINE_STATUS_ID_CLOSED="$(yaml .redmine.status_id_closed)"
}
