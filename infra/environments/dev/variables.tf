variable "project_name"          { type = string }
variable "environment"            { type = string }
variable "aws_region"             { type = string }
variable "aws_account_id"         { type = string }
variable "vpc_cidr"               { type = string }
variable "public_subnet_cidrs"    { type = list(string) }
variable "private_subnet_cidrs"   { type = list(string) }
variable "availability_zones"     { type = list(string) }
variable "ec2_key_name"           { type = string }
variable "jenkins_ami_id"         { type = string }
variable "jenkins_instance_type"  { type = string }
variable "allowed_cidr_blocks"    { type = list(string) }
variable "kubernetes_version"     { type = string }
variable "node_instance_types"    { type = list(string) }
variable "desired_nodes"          { type = number }
variable "min_nodes"              { type = number }
variable "max_nodes"              { type = number }
variable "db_username"            { type = string }
variable "db_password"            { type = string; sensitive = true }
variable "db_instance_class"      { type = string }
variable "db_storage"             { type = number }
variable "acm_certificate_arn"    { type = string; default = "" }
