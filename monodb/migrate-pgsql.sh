#!/bin/bash

backup_db() {
    [[ ! -d "$PWD/pgsqlbackup" ]] && mkdir -p "$PWD/pgsqlbackup"
    for db in ${SOURCE_PGSQL_DATABASES[@]}; do
        send_notification "Backing up $db..."
        start_time=$(date +%s)
        PGPASSWORD=$SOURCE_PGSQL_PASS pg_dump -h $SOURCE_PGSQL_HOST -p $SOURCE_PGSQL_PORT -U $SOURCE_PGSQL_USER -d $db -f "$PWD/pgsqlbackup/$db.sql" $SOURCE_PGSQL_DUMP_EXTRA_ARGS &> "$PWD/pgsqlbackup/$db.log"
        [[ "$?" == "0" ]] && { end_time=$(date +%s); send_notification 0 "Backup of $db completed in $(($end_time - $start_time)) seconds."; } || { send_notification 1 "Backup of $db failed from source, check logs.."; return 1; }
    done
}

checkconfig() {
	[[ ! -e $@ ]] && { echo "File \"$@\" does not exists, aborting..."; exit 1; }
	. "$@"

	local vars=(SOURCE_PGSQL_HOST SOURCE_PGSQL_PORT SOURCE_PGSQL_USER SOURCE_PGSQL_PASS SOURCE_PGSQL_DATABASES DEST_PGSQL_HOST DEST_PGSQL_PORT DEST_PGSQL_USER DEST_PGSQL_PASS WEBHOOK_URL)
	for a in "${vars[@]}"; do
		[[ -z ${!a} ]] && { echo "${a^} is not defined, aborting..."; return 1; }
	done
	return 0
}

restore_db() {
    [[ ! -d "$PWD/pgsqlbackup" ]] && { send_notification 1 "No backup directory found, aborting..."; return 1; }
    for db in ${SOURCE_PGSQL_DATABASES[@]}; do
        send_notification "Restoring $db..."
        start_time=$(date +%s)
        if [[ "${DEST_PGSQL_TABLE_PREFIX}" == "$db" ]]; then
            PGPASSWORD=$DEST_PGSQL_ADMIN_PASS psql -h $DEST_PGSQL_HOST -p $DEST_PGSQL_PORT -U postgres -d postgres -c "DROP DATABASE IF EXISTS $db WITH(FORCE)" &> "$PWD/pgsqlbackup/$db.log" || { send_notification 1 "Failed to drop database $db on destination, check logs.."; return 1; }
            PGPASSWORD=$DEST_PGSQL_ADMIN_PASS psql -h $DEST_PGSQL_HOST -p $DEST_PGSQL_PORT -U postgres -d postgres -c "CREATE DATABASE $db OWNER $DEST_PGSQL_USER TEMPLATE template0" &> "$PWD/pgsqlbackup/$db.log" || { send_notification 1 "Failed to create database $db on destination, check logs.."; return 1; }
            PGPASSWORD=$DEST_PGSQL_PASS psql -h $DEST_PGSQL_HOST -p $DEST_PGSQL_PORT -U $DEST_PGSQL_USER -d $db < "$PWD/pgsqlbackup/$db.sql" &> "$PWD/pgsqlbackup/$db.log" || { send_notification 1 "Failed to restore database $db on destination, check logs.."; return 1; }  
        else 
            PGPASSWORD=$DEST_PGSQL_ADMIN_PASS psql -h $DEST_PGSQL_HOST -p $DEST_PGSQL_PORT -U postgres -d postgres -c "DROP DATABASE IF EXISTS ${DEST_PGSQL_TABLE_PREFIX}$db WITH(FORCE)" &> "$PWD/pgsqlbackup/$db.log" || { send_notification 1 "Failed to drop database $db on destination, check logs.."; return 1; }
            PGPASSWORD=$DEST_PGSQL_ADMIN_PASS psql -h $DEST_PGSQL_HOST -p $DEST_PGSQL_PORT -U postgres -d postgres -c "CREATE DATABASE ${DEST_PGSQL_TABLE_PREFIX}$db OWNER $DEST_PGSQL_USER TEMPLATE template0" &> "$PWD/pgsqlbackup/$db.log" || { send_notification 1 "Failed to create database $db on destination, check logs.."; return 1; }
            PGPASSWORD=$DEST_PGSQL_PASS psql -h $DEST_PGSQL_HOST -p $DEST_PGSQL_PORT -U $DEST_PGSQL_USER -d ${DEST_PGSQL_TABLE_PREFIX}$db < "$PWD/pgsqlbackup/$db.sql" &> "$PWD/pgsqlbackup/$db.log" || { send_notification 1 "Failed to restore database $db on destination, check logs.."; return 1; }
        fi
        [[ "$?" == "0" ]] && { end_time=$(date +%s); send_notification 0 "Restore of $db completed in $(($end_time - $start_time)) seconds."; } || { send_notification 1 "Restore of $db failed on destination, check logs.."; return 1; }
    done
}

send_notification() {
    if [[ "$1" == "0" ]]; then
        local message="[ $(date '+%Y-%m-%d %H:%M:%S') ] | :check: | ${@:2}"
    elif [[ "$1" == "1" ]]; then
        local message="[ $(date '+%Y-%m-%d %H:%M:%S') ] | :red_circle: | ${@:2}"
    elif [[ "$1" == "2" ]]; then
        local message="[ $(date '+%Y-%m-%d %H:%M:%S') ] | :warning: | ${@:2}"
    else 
        local message="[ $(date '+%Y-%m-%d %H:%M:%S') ] | :info: | ${@:1}"
    fi
    local payload="{\"text\": \"$message\"}"
    curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$WEBHOOK_URL"
}


main() {
    . "$PWD/migrate-pgsql.conf"

	CONFIG_PATH="$PWD/migrate-pgsql.conf"
	[[ "$1" == '-c' ]] || [[ "$1" == '--config' ]] && { [[ -n $2 ]] && CONFIG_PATH=$2; }
    checkconfig "$CONFIG_PATH" && . "$CONFIG_PATH"
	
    backup_db && { send_notification 0 "Backup completed successfully."; }
    restore_db && { send_notification 0 "Restore completed successfully."; }
}


main "$@"
