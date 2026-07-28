#!/bin/bash
# EC2 user-data — runs once at first boot (AL2023). Passed into every
# instance via modules/ec2's `user_data` variable. Keeps environment
# bootstrapping out of AMIs/golden images: the base AL2023 AMI plus this
# script is the whole "configuration management" story for this project.
set -euo pipefail
exec > >(tee /var/log/bootstrap.log) 2>&1

echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) bootstrap starting ==="

dnf update -y

# --- CloudWatch agent: ship OS-level metrics/logs CloudWatch doesn't get
# for free from the hypervisor (memory, disk usage) -----------------------
dnf install -y amazon-cloudwatch-agent

TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)

cat <<EOF > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
{
  "agent": { "metrics_collection_interval": 60, "run_as_user": "cwagent" },
  "metrics": {
    "namespace": "IaCEnvironmentAutomation",
    "append_dimensions": { "InstanceId": "\${aws:InstanceId}" },
    "metrics_collected": {
      "mem":  { "measurement": ["mem_used_percent"] },
      "disk": { "measurement": ["used_percent"], "resources": ["/"] }
    }
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/bootstrap.log",
            "log_group_name": "/ec2/iac-environment-automation/bootstrap",
            "log_stream_name": "{instance_id}"
          }
        ]
      }
    }
  }
}
EOF

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -s \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

# --- Docker: base runtime for whatever app actually lands on this instance
dnf install -y docker
systemctl enable --now docker
usermod -aG docker ec2-user

# --- Hostname, for readability in the console/CloudWatch, not just an
# opaque instance ID -------------------------------------------------------
hostnamectl set-hostname "iac-demo-${INSTANCE_ID}"

echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) bootstrap complete ==="
