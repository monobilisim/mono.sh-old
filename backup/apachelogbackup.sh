#!/bin/bash
###~ description: This script is compress apache logs and moved by date

#~ environments
LOG_DIRECTORY="/usr/local/apache/logs"
SUBDOMAINS=('a')                                            # syntax: ('example1.com' 'sub.example2.com')
TARGETDIRECTORY="$LOG_DIRECTORY/archive"


#~ script environments
YEAROFYESTERDAY=$(date -d yesterday +%Y)
MONTHOFYESTERDAY=$(date -d yesterday +%m)
DATEOFYESTERDAY=$(date -d yesterday +%y%m%d)
YEAROFTODAY=$(date +%Y)
MONTHOFTODAY=$(date +%m)
DATEOFTODAY=$(date +%y%m%d)


#~ check crontab if not correctly configured
checkcrontab() {
	[[ "$(id -u)" != "0" ]] && { echo "Please run this script with administrative privileges.."; exit 1; }
	CRONCONFIG="$(crontab -l | grep $0 | grep '^0 0')"
	[[ ! -n $CRONCONFIG ]] && { echo -e "Cron is not correctly configured\nPlease add this line in crontab:\n\n0 0 * * * $(realpath $0) --yesterday"; exit 1; }
}


#~ check folder if exists
checkfolder() {
	[[ -n "$@" ]] && [[ ! -d "$@" ]] && mkdir -p $@
}


#~ check variable if exists
checkvariable() {
	local arr=($@)
	for a in ${arr[@]}; do
		[[ ! -n ${!a} ]] && echo "${a^} is not defined..." && exit 1
	done
}


#~ backup yesterday logs
backupofyesterdaylogs() {
	for a in ${SUBDOMAINS[@]}; do
		[[ ! -d $LOG_DIRECTORY/$a/access ]] && { echo "\"access\" directory not found in $LOG_DIRECTORY/$a"; continue; }
		pushd $LOG_DIRECTORY/$a/access
		if [[ -e "access.$DATEOFYESTERDAY.log" ]]; then
			tar czvf access.$DATEOFYESTERDAY.log.tar.gz access.$DATEOFYESTERDAY.log
			checkfolder $TARGETDIRECTORY/$a/access/$YEAROFYESTERDAY/$MONTHOFYESTERDAY
			mv access.$DATEOFYESTERDAY.log.tar.gz $TARGETDIRECTORY/$a/access/$YEAROFYESTERDAY/$MONTHOFYESTERDAY/
			rm -f access.$DATEOFYESTERDAY.log
		fi
		popd
		[[ ! -d $LOG_DIRECTORY/$a/error ]] && { echo "\"error\" directory not found in $LOG_DIRECTORY/$a"; continue; }
		pushd $LOG_DIRECTORY/$a/error
		if [[ -e "error.$DATEOFYESTERDAY.log" ]]; then
			checkfolder $TARGETDIRECTORY/$a/error
			tar czvf error.$DATEOFYESTERDAY.log.tar.gz error.$DATEOFYESTERDAY.log
			mv error.$DATEOFYESTERDAY.log.tar.gz $TARGETDIRECTORY/$a/error/
			rm -f error.$DATEOFYESTERDAY.log
		fi
		popd
	done
}


#~ backup all logs
backupofalloldlogs() {
	for a in ${SUBDOMAINS[@]}; do
		[[ ! -d $LOG_DIRECTORY/$a/access ]] && { echo "access directory not found in $LOG_DIRECTORY/$a"; continue; }
		pushd $LOG_DIRECTORY/$a/access
		for b in $(ls | grep -v "$DATEOFTODAY"); do
			YEAROFFILE="20$(echo $b | cut -d \. -f2 | head -c 2)"
			MONTHOFFILE=$(echo $b | cut -d \. -f2 | head -c 4 | tail -c 2)
			checkfolder $TARGETDIRECTORY/$a/access/$YEAROFFILE/$MONTHOFFILE/
			tar czvf $b.tar.gz $b
			mv $b.tar.gz $TARGETDIRECTORY/$a/access/$YEAROFFILE/$MONTHOFFILE/
			rm -f $b
		done
		popd
		[[ ! -d $LOG_DIRECTORY/$a/error ]] && { echo "\"error\" directory not found in $LOG_DIRECTORY/$a"; continue; }
		pushd $LOG_DIRECTORY/$a/error
		for c in $(ls | grep -v "$DATEOFTODAY"); do
			checkfolder $TARGETDIRECTORY/$a/error
			tar czvf $c.tar.gz $c
			mv $c.tar.gz $TARGETDIRECTORY/$a/error/
			rm -f $c
		done
		popd
	done
}


#~ main
main() {
	checkvariable LOG_DIRECTORY SUBDOMAINS TARGETDIRECTORY
	[[ "${#SUBDOMAINS[@]}" == "0" ]] && { echo "Subdomain list is empty..."; exit 1; }
	checkcrontab
	exit
	for a in ${SUBDOMAINS[@]}; do
		checkfolder $TARGETDIRECTORY/$a/access
		checkfolder $TARGETDIRECTORY/$a/error
	done
	case $1 in
		--yesterday)
			backupofyesterdaylogs
		;;
		--all)
			backupofalloldlogs
		;;
	esac
}

main "$@"
