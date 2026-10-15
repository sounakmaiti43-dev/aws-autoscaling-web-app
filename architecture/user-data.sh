#!/bin/bash
# =============================================================================
# user-data.sh
# EC2 user data for my-launch-template (Ubuntu Server 22.04 LTS)
#
# Runs once, as root, on first boot of every instance launched by the
# Auto Scaling group. It installs Apache and publishes a home page that shows
# which instance answered the request, which makes load balancing visible.
# =============================================================================

set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

# --- 1. Install and start the web server -------------------------------------
apt-get update -y
apt-get install -y apache2

# Start now, and again after every reboot
systemctl enable apache2
systemctl start apache2

# --- 2. Read instance details from the metadata service (IMDSv2) -------------
# IMDSv2 needs a short-lived session token before any metadata request.
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" \
  http://169.254.169.254/latest/meta-data/instance-id)

AZ=$(curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" \
  http://169.254.169.254/latest/meta-data/placement/availability-zone)

HOSTNAME_VALUE=$(hostname)

# --- 3. Publish the home page -------------------------------------------------
# Apache serves this file at "/", which is also the target group health check
# path, so it must return HTTP 200 for the instance to be marked healthy.
cat > /var/www/html/index.html <<PAGE
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Auto Scaling Web App</title>
</head>
<body style="font-family: sans-serif; text-align: center; margin-top: 15%;">
  <h1>Hello from my auto scaling web app</h1>
  <p>Instance ID: ${INSTANCE_ID}</p>
  <p>Availability Zone: ${AZ}</p>
  <p>Hostname: ${HOSTNAME_VALUE}</p>
</body>
</html>
PAGE
