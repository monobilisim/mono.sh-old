#!/usr/bin/env bash
###~ description: Check the health of the mono-k8s cluster
VERSION="0.3.0"

RED_FG=$(tput setaf 1)
GREEN_FG=$(tput setaf 2)
BLUE_FG=$(tput setaf 4)
RESET=$(tput sgr0)


[[ "$1" == '-v' ]] || [[ "$1" == '--version' ]] && {
    echo "$VERSION"
    exit 0
}

if [[ -f "$MONOK8S_CONFIG_PATH" ]]; then
    # shellcheck disable=SC1090
    . "$MONOK8S_CONFIG_PATH"
elif [[ -f /etc/monok8s-k8s-health.conf ]]; then
    # shellcheck disable=SC1091
    . /etc/monok8s-k8s-health.conf
else
    echo "Config file doesn't exist at /etc/monok8s-k8s-health.conf"
    exit 1
fi

if [ -z "$ALARM_INTERVAL" ]; then
    ALARM_INTERVAL=3
fi

# Check if kubectl is installed
if ! command -v kubectl &> /dev/null; then
	echo "kubectl is not available on PATH. Please add it to PATH."
	exit 1
fi

# https://github.com/mikefarah/yq v4.43.1 sürümü ile test edilmiştir
if [ -z "$(command -v yq)" ]; then
    read -r -p "Couldn't find yq. Do you want to download it and put it under /usr/local/bin? [y/n]: " yn
    case $yn in
    [Yy]*)
	curl -sL "$(curl -s https://api.github.com/repos/mikefarah/yq/releases/latest | grep browser_download_url | cut -d\" -f4 | grep 'yq_linux_amd64')" --output /usr/local/bin/yq
	chmod +x /usr/local/bin/yq
	;;
    [Nn]*)
        echo "Aborted"
        exit 1
        ;;
    esac
fi

function print_colour() {
    if [ "$3" != 'error' ]; then
        printf "  %-40s %s\n" "${BLUE_FG}$1${RESET}" "${GREEN_FG}$2${RESET}"
    else
        printf "  %-40s %s\n" "${BLUE_FG}$1${RESET}" "${RED_FG}$2${RESET}"
    fi
}

function echo_status() {
    echo "$1"
    echo ---------------------------------------------------
}

function alarm() {
      if [ "$SEND_ALARM" == "1" ]; then
          if [ -z "$ALARM_WEBHOOK_URLS" ]; then
	    # shellcheck disable=SC2153
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

# cat /tmp/monok8s-health/monok8s_exampledeployment-example_example_status.txt
# DATE=2021-09-29 14:00 
# locked=true
# STATUS=Running
# DEPLOYMENT=exampledeployment

# add_status "file_path" "status"
add_status() {
    if [ -f "$1" ]; then
	sed -i '/^STATUS=/d' "$1" || true 2> /dev/null
    fi
    echo "STATUS='$2'" >>"$1"
}

# add_deployment "file_path" "pod_name" "namespace"
add_deployment() {
    deployment="$(echo "$2" | sed 's/\(.*\)-[^-]*-[^-]*$/\1/')"

    if ! kubectl get deployment "$deployment" -n "$3" &> /dev/null; then
	return
    fi

    if [ -f "$1" ]; then
	sed -i '/^DEPLOYMENT=/d' "$1" || true 2> /dev/null
    fi
    echo "DEPLOYMENT='$deployment'" >>"$1"
}

# add_date "file_path" "locked"
add_date() {
    if [ -f "$1" ]; then
	sed -i '/^DATE=/d' "$1" || true 2> /dev/null
	sed -i '/^locked=/d' "$1" || true 2> /dev/null
    fi

    if [ "$2" == "locked" ]; then
	echo "locked=true" >>"$1"
    else
	echo "locked=false" >>"$1"
    fi
    
    echo "DATE='$(date "+%Y-%m-%d %H:%M")'" >>"$1"
}

function get_time_diff() {
	file_path="$1"
	if [ -f "${file_path}" ]; then
	    # shellcheck disable=SC1090
	    . "${file_path}"
	    
	    old_date=$(echo "$DATE" | awk '{print $1, $2}')

            if [ "$(uname -s | tr '[:upper:]' '[:lower:]')" == "freebsd" ]; then
                old=$(date -j -f "%Y-%m-%d %H:%M" "$old_date" "+%s")
                new=$(date -j -f "%Y-%m-%d %H:%M" "$(date '+%Y-%m-%d %H:%M')" "+%s")
            else
                old=$(date -d "$old_date" "+%s")
                new=$(date "+%s")
            fi
   
            time_diff=$(((new - old) / 60))
   
            if ((time_diff >= ALARM_INTERVAL)); then
		add_date "${file_path}"
            fi
       else
	   add_date "${file_path}"
           time_diff=0
       fi
  
       echo $time_diff
   }


function alarm_k8s() {
    case $1 in
	"worker")
	    alarm "[K8s - $IDENTIFIER] [:red_circle:] Worker node '$2' is not Ready, has status '$3'"
	;;
	"master")
	    alarm "[K8s - $IDENTIFIER] [:red_circle:] Master node '$2' is not Ready, has status '$3'"
	;;
	"pod")
	    # so the deployment is up-to-date
	    add_deployment "${file_path}" "$2" "$3"
	    alarm "[K8s - $IDENTIFIER] [:red_circle:] Pod '$2' from namespace '$3' has status '$4'"
	;;
	"cert")
	    alarm "[K8s - $IDENTIFIER] [:red_circle:] Certificate '$2' from namespace '$3' is not Ready"
	;;
	"cert_cluster")
	    alarm "[K8s - $IDENTIFIER] [:red_circle:] Cluster API cert has expired"
	;;
	"floating_unexpected")
	    alarm "[K8s - $IDENTIFIER] [:red_circle:] Floating IP '$2' returned unexpected response HTTP $3"
	;;
	"floating_noresponse")
	    alarm "[K8s - $IDENTIFIER] [:red_circle:] Floating IP '$2' is not responding"
	;;
	"ingress_response_fail")
	    alarm "[K8s - $IDENTIFIER] [:red_circle:] Ingress '$2' returned unexpected response HTTP $3"
	;;
    esac
}

function alarm_check_down() {
    [[ -z $1 ]] && {
        echo "Service type is not defined"
        return
    }
    
    file_path="/tmp/monok8s-health/monok8s_$1_$2_status.txt"
    
    if [[ -n "$4" ]]; then 
	file_path="/tmp/monok8s-health/monok8s_$1_$2_$3_status.txt"
	add_status "${file_path}" "$4"
    elif [[ -n "$3" ]]; then
	add_status "${file_path}" "$3"
    else
	add_status "${file_path}" "down"
    fi


    if [ -f "${file_path}" ]; then
	# shellcheck disable=SC1090
	. "${file_path}"
	
	if [[ "$1" == "pod" ]]; then
	    # Check if theres a new pod generated by the deployment
	    #shellcheck disable=SC2153
	    deployment_pods="$(kubectl get pods -n "$3" | sed '1d' | awk '{print $1}' | grep "$DEPLOYMENT")"
	    
	    if [[ ! "$deployment_pods" ]] && [[ "$(kubectl get pods -n "$3" | sed '1d' | awk '{print $1}' | grep -c "$2")" -eq 0 ]]; then
		rm -f "${file_path}"
		alarm "[K8s - $IDENTIFIER] [:green_circle:] Pod '$2' from namespace '$3' doesn't exist anymore, most likely replaced by ${deployment_pods//$'\n'/ }"
		return
	    fi
	fi

	old_date=$(echo "$DATE" | awk '{print $1}')
        current_date=$(date "+%Y-%m-%d")
        if [ "${old_date}" != "${current_date}" ]; then
	    add_date "${file_path}" "locked"
	    alarm_k8s "$1" "$2" "$3" "$4"
        else
	    # shellcheck disable=SC2154
            if [[ $locked == false ]]; then
                time_diff=$(get_time_diff "${file_path}")
                if ((time_diff >= ALARM_INTERVAL)); then
		    add_date "${file_path}" "locked"
		    alarm_k8s "$1" "$2" "$3" "$4"
                fi
            fi
        fi
    else
	add_date "${file_path}"
    fi
}

alarm_check_up() {
    file_path="/tmp/monok8s-health/monok8s_$1_$2_status.txt"
    
    if [[ -n "$4" ]]; then 
	file_path="/tmp/monok8s-health/monok8s_$1_$2_$3_status.txt"
    fi

    if [ -f "${file_path}" ]; then
	
	#shellcheck disable=SC1090
	. "${file_path}"

	#shellcheck disable=SC2034
	old_time=$(date -d"$DATE" "+%s")
	current_time=$(date "+%s")
	
	#shellcheck disable=SC2309
	if [[ "$STATUS" != "Running" && "((old_time + 5))" -le "$current_time" ]]; then
	    add_date "${file_path}"
	    add_status "${file_path}" "$4"
	    alarm "[K8s - $IDENTIFIER] [:green_circle:] Pod '$2' from namespace '$3' is now status '$4'"
	fi
    fi
}

function check_master() {
    echo_status "Master Node(s):"
    while IFS= read -r master; do
	NAME="$(echo "$master" | awk '{print $1}')"
	STATUS="$(echo "$master" | awk '{print $2}')"
	
	print_colour "$NAME" "$STATUS"
	
	if [ "$STATUS" != "Ready" ]; then	
	    alarm_check_down "master" "$NAME" "$STATUS"
	fi
    
    done < <(kubectl get nodes --no-headers | grep master)
}

function check_workers() {
    echo_status "Worker Node(s):"
    while IFS= read -r worker; do
	NAME="$(echo "$worker" | awk '{print $1}')"
	STATUS="$(echo "$worker" | awk '{print $2}')"
	
	print_colour "$NAME" "$STATUS"
	
	if [ "$STATUS" != "Ready" ]; then
	    alarm_check_down "worker" "$NAME" "$STATUS"
	fi
    
    done < <(kubectl get nodes --no-headers | grep -v master)
}


function check_pods() {
    echo_status "Pods:"
    while IFS= read -r pod; do
	NAMESPACE="$(echo "$pod" | awk '{print $1}')"
	NAME="$(echo "$pod" | awk '{print $2}')"
	STATUS="$(echo "$pod" | awk '{print $4}')"
    
	case $STATUS in
	    "CrashLoopBackOff" | "ImagePullBackOff" | "Error")
		print_colour "$NAMESPACE"/"$NAME" "$STATUS"
		alarm_check_down "pod" "$NAME" "$NAMESPACE" "$STATUS"
	    ;;
	    "Running")
		alarm_check_up "pod" "$NAME" "$NAMESPACE" "$STATUS"
	    ;;
	esac
    
    done < <(kubectl get pods --all-namespaces --no-headers)
} 


function check_rke2_ingress_endpoint_response() {
    for namespace in $(kubectl get namespaces | awk '{print $1}' | sed '1d'); do
	# Get all Ingress resources
    	ingresses=$(kubectl get ingress -n $namespace -o jsonpath='{.items[*].metadata.name}')

    	# Loop through each Ingress
    	for ingress in $ingresses; do
    	  # Get Ingress details (host and paths)
    	  host=$(kubectl get ingress $ingress -n $namespace -o jsonpath='{.spec.rules[0].host}')
    	  paths=$(kubectl get ingress $ingress -n $namespace -o jsonpath='{.spec.rules[*].http.paths[*].path}')
    	
    	  # Loop through each path in the Ingress
    	  for path in $paths; do
    	    # Construct the endpoint URL
    	    url="http://$(kubectl get ingress $ingress -n $namespace -o jsonpath='{.status.loadBalancer.ingress[*].ip}')$path"
    	    
    	    # Get response from the endpoint
    	    response=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: $host" "$url")
    	
    	    # Display results
    	    print_colour "$ingress" "gives $response"
	    if [ "$response" != "200" ]; then
		alarm_check_down "ingress_response_fail" "$ingress" "$response"
	    fi
    	  done
    	done
    done
}

function check_rke2_ingress_nginx() {
    # Check if master server has publishService as enabled and service as enabled on /var/lib/rancher/rke2/server/manifests/rke2-ingress-nginx.yaml
    echo_status "RKE2 Ingress Nginx:"
    
    INGRESS_NGINX_YAML="/var/lib/rancher/rke2/server/manifests/rke2-ingress-nginx.yaml"
    
    if [ ! -f "$INGRESS_NGINX_YAML" ]; then
	INGRESS_NGINX_YAML="/var/lib/rancher/rke2/server/manifests/rke2-ingress-nginx-config.yaml"
    fi

    if [[ -f "$INGRESS_NGINX_YAML" ]]; then
	print_colour "$(basename $INGRESS_NGINX_YAML)" "exists"
	publishService="$(yq eval '.spec.valuesContent' $INGRESS_NGINX_YAML | yq eval '.controller.publishService.enabled')"
	service="$(yq eval '.spec.valuesContent' $INGRESS_NGINX_YAML | yq eval '.controller.service.enabled')"
	
	if [ "$publishService" == "true" ]; then
	    print_colour "publishService" "enabled"
	else
	    print_colour "publishService" "disabled"
	fi

	if [ "$service" == "true" ]; then
	    print_colour "service" "enabled"
	else
	    print_colour "service" "disabled"
	fi

    else
	print_colour "$(basename $INGRESS_NGINX_YAML)" "doesn't exist"
    fi
    # Test floating IPs using curl
    for floating_ip in "${INGRESS_FLOATING_IPS[@]}"; do
        response=$(curl -o /dev/null -s -w "%{http_code}" "http://$floating_ip")
        if [ "$response" == "404" ]; then
            print_colour "Floating IP" "$floating_ip is accessible and returned HTTP 404"
        else
            print_colour "Floating IP" "$floating_ip is not accessible or returned HTTP $response"
	    alarm_check_down "floating_unexpected" "$floating_ip" "$response"
        fi
    done

    check_rke2_ingress_endpoint_response
}

function check_certmanager() {
    echo_status "Cert Manager:"
    if kubectl get namespace cert-manager &> /dev/null; then
	print_colour "cert-manager" "exists"
	while IFS= read -r certificate; do
	    NAMESPACE="$(echo "$certificate" | awk '{print $1}')"
	    NAME="$(echo "$certificate" | awk '{print $2}')"
	    READY="$(echo "$certificate" | awk '{print $3}')"
	    
	    if [ "$READY" != "True" ]; then
		print_colour "$NAMESPACE"/"$NAME" "not ready"
		alarm_check_down "cert" "$NAME" "$NAMESPACE"
	    fi
	done < <(kubectl get certificates --all-namespaces --no-headers 2> /dev/null)
    else
	print_colour "cert-manager" "doesn't exist"
    fi
}

function check_kube_vip() {
    echo_status "Kube-VIP:"
    if kubectl get pods -n kube-system | grep kube-vip &> /dev/null; then
	print_colour "kube-vip" "exists"
	for floating in "${K8S_FLOATING_IPS[@]}"; do
	    if ping -w 10 -c 1 "$floating" &> /dev/null; then
		print_colour "Floating IP" "$floating doesn't respond"
		alarm_check_down "floating_noresponse" "$floating"
	    fi
	done
    else
	print_colour "kube-vip" "doesn't exist"
    fi
}

function check_cluster_api_cert() {
    echo_status "Cluster API Cert:"
    
    CRT_FILE="/var/lib/rancher/rke2/server/tls/serving-kube-apiserver.crt"
    
    if [ -f "$CRT_FILE" ]; then
	print_colour "$(basename $CRT_FILE)" "exists"
    else
	print_colour "$(basename $CRT_FILE)" "doesn't exist"
	return 0
    fi
    
    expiry_date=$(openssl x509 -enddate -noout -in $CRT_FILE | cut -d= -f2 | date +"%s" -f -)
    second_to_expiry=$(( expiry_date - $(date +%s) ))
    days_to_expiry=$(( second_to_expiry / 86400 ))

    if [ $days_to_expiry -lt 1 ]; then
	print_colour "Cluster API Cert" "expired"
	alarm_check_down "cert_cluster"
    else
	print_colour "Cluster API Cert" "expires in $days_to_expiry days"
    fi
}

function main() {
    [ ! -d "/tmp/monok8s-health" ] && mkdir -p /tmp/monok8s-health
    echo
    echo Mono K8s Health "$VERSION" - "$(date)"
    echo
    check_master
    echo
    check_workers	
    echo
    check_rke2_ingress_nginx
    echo
    check_pods
    echo
    check_certmanager
    echo
    check_kube_vip
    echo
    check_cluster_api_cert
}

main
