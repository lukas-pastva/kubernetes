#!/bin/bash

# use as:
# curl -k -X POST http://event-mail-eventsource-svc.argo-workflows.svc.cluster.local:12000 -H "Content-Type: application/json" -d "{\"host\": \"chatavojtek-asdf\", \"name\": \"Y2hhdGF2b2p0ZWstYXNkZgo=\", \"email\": \"Y2hhdGF2b2p0ZWtAYS5zZAo=\",  \"email_to\": \"Y2hhdGF2b2p0ZWtAYS5zZAo=\", \"message\": \"Y2hhdGF2b2p0ZWtAYS5zZAo=\"}"

var_host="{{inputs.parameters.var_host}}"
var_name="{{inputs.parameters.var_name}}"
var_email="{{inputs.parameters.var_email}}"
var_email_to="{{inputs.parameters.var_email_to}}"
var_message="{{inputs.parameters.var_message}}"

msg=""
msg+="Name: ${var_name}\n"
msg+="Email: ${var_email}\n"
msg+="Message: ${var_message}\n"

# Word-wrap the message to 70 columns
msg=$(echo -e "$msg" | fold -s -w70)

echo -e "Message: ${msg}"

# Create the email subject
subject="Message from web ${var_host}"

# Check that var_email is provided and not empty
if [ -z "$var_email" ]; then
    echo "var_email environment variable is empty. Aborting." >&2
    exit 1
fi

# Split var_email_to (comma separated) into an array
IFS=',' read -ra recipients <<< "$var_email_to"

# Loop through the recipients and send the email individually using swaks
for recipient in "${recipients[@]}"; do
    # Trim leading/trailing whitespace from each recipient
    recipient=$(echo "$recipient" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    
    # Skip if the recipient string is empty
    if [ -z "$recipient" ]; then
        echo "Empty recipient found. Skipping..."
        continue
    fi
    
    echo "Sending email to ${recipient}..."
    
    # Send the email using swaks with STARTTLS enabled and a timeout (e.g., 30 seconds)
    swaks --timeout 30 \
          --to "$recipient" \
          --from "$MAIL_USERNAME" \
          --server "smtp.office365.com" \
          --port "587" \
          --auth LOGIN \
          --auth-user "$MAIL_USERNAME" \
          --auth-password "$MAIL_PASSWORD" \
          --tls \
          --header "Subject: ${subject}" \
          --body "$var_message"
    
    if [ $? -ne 0 ]; then
        echo "Email sending error to ${recipient}" >&2
    fi
done

# Optionally, output the message (or a confirmation) to the client.
echo -e "$msg"