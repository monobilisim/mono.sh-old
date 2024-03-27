#!/bin/bash

usage() {
	echo -e "Usage: $0 [-d <param>] [-s <param>] [-h]"
	echo -e '\t-d | --destination "aws-bucket|aws-access-key|aws-secret-key|aws-region" : Destination bucket info'
	echo -e '\t-D | --dry-run     											            : Dry run'
	echo -e '\t-s | --source      "aws-bucket|aws-access-key|aws-secret-key|aws-region" : Source bucket info'
	echo -e "\t-h | --help                                                              : Print this message."
}


main() {
	opt=($(getopt -l "destination:,dry-run,source:,help" -o "d:,D,s:,h" -n "$0" -- "$@"))
	[[ "${#opt[@]}" == "1" ]] && { usage; exit 1; }
	eval set -- "${opt[@]}"

	oldIFS=$IFS
	while true; do
		[[ "$1" == '-d' ]] || [[ "$1" == '--destination' ]] && { [[ -n $2 ]] && IFS='|' dest_info=($2)  ; }
		[[ "$1" == '-s' ]] || [[ "$1" == '--source'      ]] && { [[ -n $2 ]] && IFS='|' source_info=($2); }
		[[ "$1" == '-D' ]] || [[ "$1" == '--dry-run'     ]] && { dry_run=1; }
		shift
		[[ "$1" == '--' ]] && break
	done
	IFS=$oldIFS

	[[ -z ${dest_info[0]}   ]] && { echo "Destination bucket info is required, aborting..."; exit 1; } || dest_bucket=${dest_info[0]}
	[[ -z ${dest_info[1]}   ]] && { echo "Destination access key is required, aborting..." ; exit 1; } || dest_access_key_id=${dest_info[1]}
	[[ -z ${dest_info[2]}   ]] && { echo "Destination secret key is required, aborting..." ; exit 1; } || dest_secret_key_id=${dest_info[2]}
	[[ -z ${dest_info[3]}   ]] && { echo "Destination region is required, aborting..."     ; exit 1; } || dest_region=${dest_info[3]}
	[[ -z ${source_info[0]} ]] && { echo "Source bucket info is required, aborting..."     ; exit 1; } || source_bucket=${source_info[0]}
	[[ -z ${source_info[1]} ]] && { echo "Source access key is required, aborting..."      ; exit 1; } || source_access_key_id=${source_info[1]}
	[[ -z ${source_info[2]} ]] && { echo "Source secret key is required, aborting..."      ; exit 1; } || source_secret_key_id=${source_info[2]}
	[[ -z ${source_info[3]} ]] && { echo "Source region is required, aborting..."          ; exit 1; } || source_region=${source_info[3]}

	[[ ! -d ~/.aws                       ]] && mkdir ~/.aws
	[[ ! -f ~/.aws/credentials           ]] && touch ~/.aws/credentials
	[[ ! -f ~/.aws/config                ]] && touch ~/.aws/config
	[[ ! -d ~/.config/rclone             ]] && mkdir -p ~/.config/rclone
	[[ ! -f ~/.config/rclone/rclone.conf ]] && touch ~/.config/rclone/rclone.conf

	[[ -z $(grep -i "source" ~/.aws/credentials)                                            ]] && echo "[source]" >> ~/.aws/credentials
	[[ -z $(grep -A2 "source" ~/.aws/credentials | grep aws_access_key_id)                  ]] && echo "aws_access_key_id = $source_access_key_id" >> ~/.aws/credentials
	[[ -z $(grep -A2 "source" ~/.aws/credentials | grep aws_secret_access_key)              ]] && echo "aws_secret_access_key = $source_secret_key_id" >> ~/.aws/credentials
	[[ -z $(grep -i "profile source" ~/.aws/config)                                         ]] && echo "[profile source]" >> ~/.aws/config
	[[ -z $(grep -A1 "profile source" ~/.aws/config | grep region)                          ]] && echo "region = $source_region" >> ~/.aws/config
	[[ -z $(grep -i "source" ~/.config/rclone/rclone.conf)                                  ]] && echo "[source]" >> ~/.config/rclone/rclone.conf
	[[ -z $(grep -A5 "source" ~/.config/rclone/rclone.conf | grep type)                     ]] && echo "type = s3" >> ~/.config/rclone/rclone.conf
	[[ -z $(grep -A5 "source" ~/.config/rclone/rclone.conf | grep provider)                 ]] && echo "provider = AWS" >> ~/.config/rclone/rclone.conf
	[[ -z $(grep -A5 "source" ~/.config/rclone/rclone.conf | grep access_key_id)            ]] && echo "access_key_id = $source_access_key_id" >> ~/.config/rclone/rclone.conf
	[[ -z $(grep -A5 "source" ~/.config/rclone/rclone.conf | grep secret_access_key)        ]] && echo "secret_access_key = $source_secret_key_id" >> ~/.config/rclone/rclone.conf
	[[ -z $(grep -A5 "source" ~/.config/rclone/rclone.conf | grep region)                   ]] && echo "region = $source_region" >> ~/.config/rclone/rclone.conf
	[[ -z $(grep -A5 "source" ~/.config/rclone/rclone.conf | grep location_constraint)      ]] && echo "location_constraint = $source_region" >> ~/.config/rclone/rclone.conf

	[[ -z $(grep -i "destination" ~/.aws/credentials)                                       ]] && echo "[destination]" >> ~/.aws/credentials
	[[ -z $(grep -A2 "destination" ~/.aws/credentials | grep aws_access_key_id)             ]] && echo "aws_access_key_id = $dest_access_key_id" >> ~/.aws/credentials
	[[ -z $(grep -A2 "destination" ~/.aws/credentials | grep aws_secret_access_key)         ]] && echo "aws_secret_access_key = $dest_secret_key_id" >> ~/.aws/credentials
	[[ -z $(grep -i "profile destination" ~/.aws/config)                                    ]] && echo "[profile destination]" >> ~/.aws/config
	[[ -z $(grep -A1 "profile destination" ~/.aws/config | grep region)                     ]] && echo "region = $dest_region" >> ~/.aws/config
	[[ -z $(grep -i "destination" ~/.config/rclone/rclone.conf)                             ]] && echo "[destination]" >> ~/.config/rclone/rclone.conf
	[[ -z $(grep -A5 "destination" ~/.config/rclone/rclone.conf | grep type)                ]] && echo "type = s3" >> ~/.config/rclone/rclone.conf
	[[ -z $(grep -A5 "destination" ~/.config/rclone/rclone.conf | grep provider)            ]] && echo "provider = AWS" >> ~/.config/rclone/rclone.conf
	[[ -z $(grep -A5 "destination" ~/.config/rclone/rclone.conf | grep access_key_id)       ]] && echo "access_key_id = $dest_access_key_id" >> ~/.config/rclone/rclone.conf
	[[ -z $(grep -A5 "destination" ~/.config/rclone/rclone.conf | grep secret_access_key)   ]] && echo "secret_access_key = $dest_secret_key_id" >> ~/.config/rclone/rclone.conf
	[[ -z $(grep -A5 "destination" ~/.config/rclone/rclone.conf | grep region)              ]] && echo "region = $dest_region" >> ~/.config/rclone/rclone.conf
	[[ -z $(grep -A5 "destination" ~/.config/rclone/rclone.conf | grep location_constraint) ]] && echo "location_constraint = $dest_region" >> ~/.config/rclone/rclone.conf

	if [[ -z "$dry_run" ]]; then
		echo "===> Creating destination bucket"
		aws s3 mb --profile destination s3://${dest_bucket}-tmp
		aws s3api put-public-access-block --profile destination --bucket ${dest_bucket}-tmp --public-access-block-configuration "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false"
		aws s3api put-bucket-policy --bucket ${dest_bucket}-tmp --profile destination --policy '{
			"Version": "2012-10-17",
			"Statement": [
				{
					"Sid": "PublicReadGetObject",
					"Effect": "Allow",
					"Principal": "*",
					"Action": "s3:GetObject",
					"Resource": "arn:aws:s3:::'${dest_bucket}-tmp'/*"
				}
			]
		}'
		echo "===> Syncing source bucket to destination bucket"
		rclone sync source:$source_bucket destination:${dest_bucket}-tmp
		aws s3 ls --profile destination s3://${dest_bucket}-tmp
		echo "===> Deleting source bucket"
		read -p "Bucket $source_bucket will be deleted, are you sure? (y/N): "
		if [[ $REPLY =~ ^[Yy]$ ]]; then
			aws s3 rb --profile source s3://$source_bucket --force
		fi
		start_time=$(date +%s)
		aws s3 mb --profile destination s3://$dest_bucket >/dev/null 2>&1
		while [[ $? -ne 0 ]]; do
			echo "===> Bucket $dest_bucket already exists, waiting 5s... ($(($(date +%s) - start_time)) seconds)"
			sleep 5
			aws s3 mb --profile destination s3://$dest_bucket > /dev/null 2>&1
		done
		end_time=$(date +%s)
		aws s3 cp --profile destination s3://${dest_bucket}-tmp s3://$dest_bucket --recursive
		echo "===> Migration completed in $((end_time - start_time)) seconds"
	fi
}


main "$@"
