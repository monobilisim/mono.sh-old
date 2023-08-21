#!/usr/bin/bash
###~ description: acme.sh helper with geoip toggler support, nginx support and multiple domain support

# load config
if [[ -e "/etc/sslrenew.conf" ]]; then
    . /etc/sslrenew.conf
else
    echo "/etc/sslrenew.conf not found, pulling from git"
    wget -q https://raw.githubusercontent.com/monobilisim/mono.sh/main/config/sslrenew.conf 
	echo "Please edit \"sslrenew.conf\" file and try again."
	exit 0
fi


# set variables
today="$(date +%d%m%Y)"
firstdomain="${domains[0]}"
parameters=""


# logger system
log_and_execute() {
    local command="$@"
    echo "Command: $command" | tee -a "$log_file"
    eval "$command" >> "$log_file" 2>&1
    local exit_code="$?"
    if [[ "$exit_code" == "0" ]]; then
        echo "Command executed successfully" | tee -a "$log_file"
    else
        echo "Command failed: $exit_code" | tee -a "$log_file"
        exit $exit_code
    fi
}


# check variables
checkvariable() {
    local arr=($@)
    for a in ${arr[@]}; do
        [[ ! -n ${!a} ]] && echo "${a^} is not defined" && exit 1
    done
}


# main
main() {
  [[ "$geoiptoggle" == "true" ]] && log_and_execute "yes | cp -rf $nginx_conf_path/nginx.conf{.geoipoff,}"
  log_and_execute "yes | cp -rf $nginx_conf_path/ssl.crt/{$certname.crt,old/$certname.crt.$today}"
  log_and_execute "yes | cp -rf $nginx_conf_path/ssl.crt/{$certname.key,old/$certname.key.$today}"
  [[ "$geoiptoggle" == "true" ]] && log_and_execute "${nginx_bin_path} -s reload"

  for a in "${domains[@]}"; do
    parameters+="-d $a "
  done

  [[ ! -n "$webroot_path" ]] && parameters+="--nginx " || parameters+="--webroot ${webroot_path} "

  log_and_execute "${acme_sh_path}/acme.sh --issue $parameters --debug"
  [[ "$(${acme_sh_path}/acme.sh --version | grep v | tr -dc [:digit:])" -ge "306" ]] && ecc="true"


  log_and_execute "yes | cp -rf ${acme_sh_path}/${firstdomain}${ecc:+_ecc}/fullchain.cer $nginx_conf_path/ssl.crt/$certname.crt"
  log_and_execute "yes | cp -rf ${acme_sh_path}/${firstdomain}${ecc:+_ecc}/$firstdomain.key $nginx_conf_path/ssl.crt/$certname.key"
  [[ "$geoiptoggle" == "true" ]] && log_and_execute "yes | cp -rf $nginx_conf_path/nginx.conf{.geoipon,}"
  [[ "$geoiptoggle" == "true" ]] && log_and_execute "${nginx_bin_path} -s reload"
}

# start process
checkvariable log_file acme_sh_path certname nginx_bin_path nginx_conf_path geoiptoggle domains | tee -a "$log_file"
main | tee -a "$log_file"

