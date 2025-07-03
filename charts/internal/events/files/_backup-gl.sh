#!/bin/bash

source functions.inc.sh

# config s3
config="[s3]
type = s3
env_auth = false
provider = AWS
region = auto
access_key_id = ${BACKUP_S3_KEY}
secret_access_key = ${BACKUP_S3_SECRET}
endpoint = ${BACKUP_S3_URL}
"
# force_path_style = true

config_file="/tmp/rclone.conf"
mkdir -p "$(dirname "$config_file")"
echo "$config" > "$config_file"

# --------------------------------------------------------------------------------------------------------------------
# Backing up tronic-sk
export group_id=54307567
export gitlab_private_token="${GIT_TOKEN_READ}"
export rclone_bucket="${BUCKET_NAME}"
gitlab_backup
# --------------------------------------------------------------------------------------------------------------------