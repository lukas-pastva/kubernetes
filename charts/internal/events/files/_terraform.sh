#!/bin/bash

sleep 600

source functions.inc.sh

# mount s3
mkdir -p /tmp/tfstate
echo ${TERRAFORM_S3_KEY}:${TERRAFORM_S3_SECRET} > /etc/passwd-s3fs
chmod 600 /etc/passwd-s3fs
s3fs customer-tronic-sk-terraform /tmp/tfstate -o allow_other -o use_path_request_style -o url=${TERRAFORM_S3_URL}

# copy files
cp /home/generated/..data/* .
cp /tmp/tfstate/terraform.tfstate . || true > /dev/null
if [ ! -f /tmp/tfstate/terraform.tfstate ]; then
    echo "The file /tmp/tfstate/terraform.tfstate does not exist. Exiting..."
    sleep 300
    exit 1
fi

# terraform init
terraform init

# check if changes will be done
terraform plan -detailed-exitcode
PLAN_EXIT_CODE=$?
if [ $PLAN_EXIT_CODE -eq 2 ]; then
    echo "---> Applying!"
    export TF_RESULT=$(terraform apply -auto-approve)
    echo "---> TF_RESULT: ${TF_RESULT}"

    echo "---> Backing the terraform.tfstate file with the current date and time."
    DATE=$(date +"%Y-%m-%d-%H-%M-%S")
    cp terraform.tfstate /tmp/tfstate/terraform-$DATE.tfstate

    echo "---> Copying terraform.tfstate back into /tmp/tfstate/, overwriting the existing file."
    cp terraform.tfstate /tmp/tfstate/

    echo "---> Sending message to Slack"              
    export ansi_escape='(\x1B[@-_]|\x1B\[)[0-?]*[ -/]*[@-~]'
    export MESSAGE=$(echo "${TF_RESULT}" | sed -r "s/$ansi_escape//g")
    MESSAGE=${MESSAGE//\'/}
    MESSAGE=${MESSAGE//\"}
    curl -sX POST ${SLACK_HOOK_TRONIC_SK} -H "Content-Type: application/json" -d "{\"text\": \"${MESSAGE}\"}"
    echo -e "${MESSAGE}"
else
    echo "---> No changes detected."
fi