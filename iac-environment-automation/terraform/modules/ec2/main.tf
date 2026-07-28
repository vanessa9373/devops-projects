terraform {
  required_providers {
    aws = { source = "hashicorp/aws" }
  }
}

# Always resolve the latest AL2023 AMI at apply time rather than pinning an
# ID — pinned AMI IDs are the #1 reason "terraform apply" from six months
# ago silently deploys an EOL, unpatched image today.
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "this" {
  count = var.instance_count

  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_ids[count.index % length(var.subnet_ids)]
  vpc_security_group_ids = var.security_group_ids
  iam_instance_profile   = var.iam_instance_profile
  user_data              = var.user_data
  # No key_name — access is via SSM Session Manager (modules/iam), not SSH keys.

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_tokens   = "required" # IMDSv2 only
    http_endpoint = "enabled"
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-${count.index}" })
}
