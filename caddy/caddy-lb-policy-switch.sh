#!/usr/bin/env bash
###~ description: Switch the load balancing policy of a Caddy server

if [[ "$1" == "--version" ]] || [[ "$1" == "-v" ]]; then 
    echo "v0.4.0" 
    exit 0 
fi

function debug() {
    if [[ "$DEBUG" -eq 1 ]]; then
        echo "debug: $1"
    fi
}

function verbose() {
    if [[ "$VERBOSE" -eq 1 ]]; then
        echo "$1"
    fi
}

function hostname_to_url() {
    local hostname="$1"

    # Split the hostname into parts
    IFS='-' read -ra parts <<< "$hostname"

    # Check if we have enough parts
    if (( ${#parts[@]} < 3 )); then
        echo "Error: Invalid hostname format" >&2
        return 1
    fi

    # Extract the relevant parts
    local domain_part="${parts[0]}"
    local env_part="${parts[1]}" 
    local lb_part="${parts[2]}" 

    # Construct the URL
    echo "https://api.${lb_part}.${env_part}.${domain_part}.biz.tr" 
}

function alarm() {
    if [ "$SEND_ALARM" == "1" ]; then
        if [ -z "$ALARM_WEBHOOK_URLS" ]; then
            #shellcheck disable=SC2153
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
    
    read IDENTIFIER < <(awk -F '[@;]' '{print $2}' <<< "$URL")
    read ACTUAL_URL < <(awk -F '[@;]' '{print $1}' <<< "$URL")
    
    debug "Checking $ACTUAL_URL for $IDENTIFIER"
    debug "Username-Password: $USERNAME_PASSWORD"

    # Not to be confused with CADDY_SERVERS
    SERVERS="$(curl -s -u "$USERNAME_PASSWORD" "$ACTUAL_URL"/config/apps/http/servers | jq -r 'keys | join(" ")')"
   
    debug "Servers: $SERVERS"

    for SERVER in $SERVERS; do  
        
        debug "checking server: $SERVER"

        # Identify the routes
        LENGTH="$(curl -s -u "$USERNAME_PASSWORD" "$ACTUAL_URL"/config/apps/http/servers/"${SERVER:?}"/routes | jq length)"
        
        debug "Routes: $LENGTH"

        for route in $(seq 0 $((LENGTH-1))); do
            REQ_URL="$ACTUAL_URL/config/apps/http/servers/${SERVER:?}/routes/$route"
            REQ="$(curl -u "$USERNAME_PASSWORD" -s "$REQ_URL")"
            export REQ
            export REQ_URL

            if (echo "$REQ" | jq -r '.match[].host | join(" ")' 2> /dev/null | grep -qw "$URL_TO_FIND"); then
                echo "Match found, route: $route, server: $SERVER"
                change_upstreams "$1" "$2" "$IDENTIFIER"
            fi
        done
    done
}

function change_upstreams() {
    echo "Changing upstreams"
    
    if [[ "$NO_CHANGES_COUNTER" -ge "${NO_CHANGES_EXIT_THRESHOLD:-3}" ]]; then
        echo "No changes needed for $NO_CHANGES_EXIT_THRESHOLD times, exiting"
        exit 0
    fi

    if [[ -z "$IDENTIFIER" ]]; then
        IDENTIFIER="$URL"
    fi

    case $1 in
        first)
            REQ_TO_SEND="$(echo "$REQ" | jq --arg SRVNAME "$2" -cMr '
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
                ')"

            if [[ "$REQ_TO_SEND" == "$REQ" ]] && [[ "$SERVER_OVERRIDE_CONFIG" != "1" ]]; then
                echo "No changes needed as the upstreams are already in the first_$2 order"
                NO_CHANGES_COUNTER=$((NO_CHANGES_COUNTER+1))
                export NO_CHANGES_COUNTER
                if [[ "$VERBOSE" -eq 1 ]]; then
                    alarm "[Caddy lb-policy Switch] [$IDENTIFIER] [$URL_TO_FIND] [:check:] No changes needed as the upstreams are already in the first_$2 order"
                fi
                return
            else
                echo "Sending request to change upstreams"
                
                if curl -u "$USERNAME_PASSWORD" -X PATCH -H "Content-Type: application/json" -d "$REQ_TO_SEND" "$REQ_URL" 2> /tmp/caddy-lb-policy-switch-error.log; then
                    alarm "[Caddy lb-policy Switch] [$IDENTIFIER] [$URL_TO_FIND] [:check:] Switched upstreams to first_$2"
                else
                    alarm "[Caddy lb-policy Switch] [$IDENTIFIER] [$URL_TO_FIND] [:red_circle:] Failed to switch upstreams to first_$2\nError log: \`\`\`\n$(cat /tmp/caddy-lb-policy-switch-error.log)\n\`\`\`"
                fi

            fi
            ;;
        round_robin | ip_hash)
            REQ_TO_SEND="$(echo "$REQ" | jq --arg LB_POLICY "$1" -cMr '
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
                ')"
            if [[ "$REQ_TO_SEND" == "$REQ" ]] && [[ "$SERVER_OVERRIDE_CONFIG" != "1" ]]; then
                echo "No changes needed as the upstreams are already in the $1 order"
                NO_CHANGES_COUNTER=$((NO_CHANGES_COUNTER+1))
                export NO_CHANGES_COUNTER
                if [[ "$VERBOSE" -eq 1 ]]; then
                    alarm "[Caddy lb-policy Switch] [$IDENTIFIER] [$URL_TO_FIND] [:check:] No changes needed as the upstreams are already in the $1 order"
                fi
                return
            else
                echo "Sending request to change lb_policy to $1"
                if curl -u "$USERNAME_PASSWORD" -X PATCH -H "Content-Type: application/json" -d "$REQ_TO_SEND" "$REQ_URL" 2> /tmp/caddy-lb-policy-switch-error.log; then
                    alarm "[Caddy lb-policy Switch] [$IDENTIFIER] [$URL_TO_FIND] [:check:] Switched lb_policy to $1"
                else
                    alarm "[Caddy lb-policy Switch] [$IDENTIFIER] [$URL_TO_FIND] [:red_circle:] Failed to switch lb_policy to $1\nError log: \`\`\`\n$(cat /tmp/caddy-lb-policy-switch-error.log)\n\`\`\`"
                fi
            fi
            ;;
        *)
            echo "Invalid load balancing command"
            exit 1
            ;;
    esac
}

function adjust_api_urls() {
    CADDY_API_URLS_NEW=()
    
    for i in "${CADDY_LB_URLS[@]}"; do
        for URL_UP in "${CADDY_API_URLS[@]}"; do
   
            if [[ "${#CADDY_API_URLS_NEW[@]}" -eq $((${#CADDY_LB_URLS[@]} - 1)) ]]; then
                break
            fi

            URL="${URL_UP#*@}"
            USERNAME_PASSWORD="${URL_UP%%@*}"
            
            verbose "LB $i"
            url_new="$(hostname_to_url "$(curl -s "$i" | grep "Hostname:" | awk '{print $2}')")"
            if [[ "$url_new" == "$URL" ]]; then
                debug "$url_new is the same as URL, adding to CADDY_API_URLS_NEW"
                CADDY_API_URLS_NEW+=("$URL_UP") # Make sure the ones that respond first are added first
                verbose "CADDY_API_URLS_NEW: ${CADDY_API_URLS_NEW[*]}"
            fi
        done
    
    done

    for URL_UP in "${CADDY_API_URLS[@]}"; do
        CADDY_API_URLS_NEW+=("$URL_UP")
    done

    readarray -t CADDY_API_URLS_NEW < <(printf '%s\n' "${CADDY_API_URLS_NEW[@]}" | sort -u)
    export CADDY_API_URLS_NEW

}

if [ ! -d /etc/glb ]; then
    echo "No configuration files found on /etc/glb"
    exit 1
fi

for conf in /etc/glb/*.conf; do
    [ ! -f "$conf" ] && continue
    
    #shellcheck disable=SC1090
    . "$conf"
    
    echo "---------------------------------"
    echo "Config: $conf"

    for i in CADDY_API_URLS CADDY_SERVERS; do
        if [[ ${#i[@]} -eq 0 ]]; then
            echo "$i is empty, please define it on $conf"
            exit 1
        fi
    done
        
    if [[ ${#CADDY_LB_URLS[@]} -eq 0 ]] && [[ $NO_DYNAMIC_API_URLS -ne 1 ]]; then
        echo "CADDY_LB_URLS is empty, please define it on $conf"
        exit 1
    fi
    
    if [[ "$NO_DYNAMIC_API_URLS" -ne 1 ]]; then
        debug "CADDY_API_URLS: ${CADDY_API_URLS[*]}"
        adjust_api_urls
        debug "CADDY_API_URLS_NEW: ${CADDY_API_URLS_NEW[*]}"
    fi
    
    if [[ "$LOOP_ORDER" == "SERVERS" ]]; then
        for URL_TO_FIND in "${CADDY_SERVERS[@]}"; do
            for URL_UP in "${CADDY_API_URLS_NEW[@]}"; do
                URL="${URL_UP#*@}"
                USERNAME_PASSWORD="${URL_UP%%@*}"
                echo '---------------------------------'
                echo "Checking '$URL_TO_FIND' on '$URL'"
                identify_request "$1" "$2"
                echo '---------------------------------'
            done
        done
    else
        for URL_UP in "${CADDY_API_URLS_NEW[@]}"; do
            URL="${URL_UP#*@}"
            USERNAME_PASSWORD="${URL_UP%%@*}"
            for URL_TO_FIND in "${CADDY_SERVERS[@]}"; do
                echo '---------------------------------'
                echo "Checking '$URL_TO_FIND' on '$URL'"
                identify_request "$1" "$2"
                echo '---------------------------------'
            done
        done
    fi 


    for i in CADDY_API_URLS CADDY_API_URLS_NEW CADDY_SERVERS ALARM_BOT_USER_EMAILS ALARM_WEBHOOK_URLS ALARM_BOT_EMAIL ALARM_BOT_API_KEY ALARM_BOT_API_URL ALARM_WEBHOOK_URL SEND_ALARM SEND_DM_ALARM NO_CHANGES_EXIT_THRESHOLD CADDY_LB_URLS NO_DYNAMIC_API_URLS SERVER_OVERRIDE_CONFIG LOOP_ORDER VERBOSE DEBUG; do
        unset $i
    done

    echo "Done with $conf"
    echo "---------------------------------"
done
