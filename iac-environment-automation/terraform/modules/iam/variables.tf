variable "name_prefix" {
  type = string
}

variable "managed_policy_arns" {
  description = "AWS managed policy ARNs to attach to the instance role"
  type        = list(string)
  default = [
    # SSM Session Manager — shell access without SSH keys, bastions, or open port 22.
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
    # Lets the CloudWatch agent installed by scripts/ec2-userdata.sh ship metrics/logs.
    "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy",
  ]
}

variable "tags" {
  type    = map(string)
  default = {}
}
