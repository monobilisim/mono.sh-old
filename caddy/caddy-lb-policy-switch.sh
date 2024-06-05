#!/usr/bin/env bash
###~ description: Switch the load balancing policy of a Caddy server

if [[ "$1" == "--version" ]] || [[ "$1" == "-v" ]]; then 
    echo "v0.1.0" 
    exit 0 
fi

function debug() {
    if [[ "$DEBUG" -eq 1 ]]; then
        echo "debug: $@"
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


function identify_request() {
    debug "Checking $URL"
    debug "Username-Password: $USERNAME_PASSWORD"


    # Not to be confused with CADDY_SERVERS
    SERVERS="$(curl -s -u "$USERNAME_PASSWORD" "$URL"/config/apps/http/servers | jq -r 'keys | join(" ")')"
   
    debug "Servers: $SERVERS"

    for SERVER in $SERVERS; do  
        
        debug "checking server: $SERVER"

        # Identify the routes
        LENGTH="$(curl -s -u $USERNAME_PASSWORD $URL/config/apps/http/servers/${SERVER:?}/routes | jq length)"
        
        debug "Routes: $LENGTH"

        for route in $(seq 0 $((LENGTH-1))); do
            export REQ_URL="$URL/config/apps/http/servers/${SERVER:?}/routes/$route"
            export REQ="$(curl -u "$USERNAME_PASSWORD" -s $REQ_URL)"
            
            if (echo "$REQ" | jq -r '.match[].host | join(" ")' 2> /dev/null | grep -qw "$URL_TO_FIND"); then
                echo "Match found, route: $route, server: $SERVER"
                change_upstreams "$1" "$2"
            fi
        done
    done
}

function change_upstreams() {
    echo "Changing upstreams"
    case $1 in
        first)
            curl -u "$USERNAME_PASSWORD" -X PATCH -H "Content-Type: application/json" -d "$(echo "$REQ" | jq --arg SRVNAME "$2" -cMr '
                .handle[] |= (
                  .routes[] |= (
                    .handle[] |= (
                      if .handler == "reverse_proxy" then
                        (
                          if (.upstreams | length) == 2 and (.upstreams[1].dial | contains($SRVNAME)) 
                            then .upstreams |= [.[1], .[0]] 
                            else . 
                          end
                        )
                        | (.load_balancing.selection_policy.policy = "first") # Set policy here
                      else . 
                      end
                    )
                  )
                )
                ')" "$REQ_URL"
            
            if [ $? -eq 0 ]; then
                alarm "[Caddy lb-policy Switch] [$URL] [$URL_TO_FIND] [:check:] Switched lb_policy to first_$2"
            else
                alarm "[Caddy lb-policy Switch] [$URL] [$URL_TO_FIND] [:red_circle:] Failed to switch lb_policy to first_$2"
            fi
            
            ;;
        round_robin | ip_hash)
            curl -u "$USERNAME_PASSWORD" -X PATCH -H "Content-Type: application/json" -d "$(echo "$REQ" | jq --arg LB_POLICY "$1" -cMr '
                .handle[] |= (
                  .routes[] |= (
                    .handle[] |= (
                      if .handler == "reverse_proxy" 
                      then .load_balancing.selection_policy.policy = $LB_POLICY 
                      else . 
                      end
                    )
                  )
                )
                ')" "$REQ_URL"

            if [ $? -eq 0 ]; then
                alarm "[Caddy lb-policy Switch] [$URL] [$URL_TO_FIND] [:check:] Switched lb_policy to $1"
            else
                alarm "[Caddy lb-policy Switch] [$URL] [$URL_TO_FIND] [:red_circle:] Failed to switch lb_policy to $1"
            fi

            ;;
        *)
            echo "Invalid load balancing command"
            exit 1
            ;;
    esac
}

if [ ! -d /etc/glb ]; then
    echo "No configuration files found on /etc/glb"
    exit 1
fi

for conf in /etc/glb/*.conf; do
    [ ! -f "$conf" ] && continue
    
    . "$conf"
    
    echo "---------------------------------"
    echo "Config: $conf"

    if [ ${#CADDY_API_URLS[@]} -eq 0 ]; then
        echo "CADDY_API_URLS is empty, please define it on $conf"
        exit 1
    fi

    if [ ${#CADDY_SERVERS[@]} -eq 0 ]; then
        echo "CADDY_SERVERS is empty, please define it on $conf"
        exit 1
    fi


    for URL_UP in ${CADDY_API_URLS[@]}; do
        URL="${URL_UP#*@}"
        USERNAME_PASSWORD="${URL_UP%%@*}"
        for URL_TO_FIND in ${CADDY_SERVERS[@]}; do
            echo '---------------------------------'
            echo "Checking '$URL_TO_FIND' on '$URL'"
            identify_request "$1" "$2"
            echo '---------------------------------'
        done
    done
    
    for i in CADDY_API_URLS CADDY_SERVERS ALARM_BOT_USER_EMAILS ALARM_WEBHOOK_URLS ALARM_BOT_EMAIL ALARM_BOT_API_KEY ALARM_BOT_API_URL ALARM_WEBHOOK_URL SEND_ALARM SEND_DM_ALARM; do
        unset $i
    done

    echo "Done with $conf"
    echo "---------------------------------"
done
