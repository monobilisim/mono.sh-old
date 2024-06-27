#!/usr/bin/env bash
###~ description: Common functions for all scripts

#shellcheck disable=SC2034
#shellcheck disable=SC2120

CONFIG_PATH=/etc/mono.sh

function yaml() {
    
    if [[ "$CONFIG_PATH"/$2.yaml ]]; then
        CONFIG_PATH_DATA="$2.yaml"
    elif [[ "$CONFIG_PATH"/$2.yml ]]; then
        CONFIG_PATH_DATA="$2.yml"
    else
        echo "Config file $CONFIG_PATH/$2.yaml nor $CONFIG_PATH/$2.yml not found"
        exit 1
    fi

    OUTPUT=$(yq "$1" $CONFIG_PATH/"$2")

    case $OUTPUT in
        null)
            if [[ "$REQUIRED" == "true" && -z $2 ]]; then
                echo "Required field '$1' not found in $CONFIG_PATH/$2"
                exit 1
            fi

            if [[ -z $2 ]]; then
                echo "''"
            else
                echo "$3"
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

function check_yq() {
    # https://github.com/mikefarah/yq v4.43.1 sürümü ile test edilmiştir
    if [ -z "$(command -v yq)" ]; then
    
        if [[ "$INSTALL_YQ" == "1" ]]; then
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
}

function parse_common() {
    # Alarm
    readarray -t ALARM_WEBHOOK_URLS < <(yaml .alarm.webhook_urls[] "main")
    IDENTIFIER="$(yaml .identifier "main")"
    SEND_ALARM="$(yaml '.send_alarm' "main" 1)"

    ## Bot
    SEND_DM_ALARM="$(yaml '.alarm.bot.enabled' "main" 0)"
    ALARM_BOT_API_URL="$(yaml .alarm.bot.alarm_url "main")"
    ALARM_BOT_EMAIL="$(yaml .alarm.bot.email "main")"
    ALARM_BOT_API_KEY="$(yaml .alarm.bot.api_key "main")"
    readarray -t ALARM_BOT_USER_EMAILS < <(yaml .alarm.bot.user_emails[] "main")

    ## Redmine (WIP)
    REDMINE_API_KEY="$(yaml .redmine.api_key "main")"
    REDMINE_URL="$(yaml .redmine.url "main")"
    REDMINE_ENABLE="$(yaml '.redmine.enabled' "main" 1)"
    REDMINE_PROJECT_ID="$(yaml .redmine.project_id "main")"
    REDMINE_TRACKER_ID="$(yaml .redmine.tracker_id "main")"
    REDMINE_PRIORITY_ID="$(yaml .redmine.priority_id "main")"
    REDMINE_STATUS_ID="$(yaml .redmine.status_id "main")"
    REDMINE_STATUS_ID_CLOSED="$(yaml .redmine.status_id_closed "main")"
}

check_yq
parse_common
