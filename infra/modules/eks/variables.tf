variable "project_name"       { type = string }
variable "environment"         { type = string }
variable "cluster_name"        { type = string }
variable "kubernetes_version"  { type = string; default = "1.32" }
variable "vpc_id"              { type = string }
variable "public_subnet_ids"   { type = list(string) }
variable "jenkins_sg_id"       { type = string }
variable "alb_sg_id"           { type = string }
variable "jenkins_role_arn"    { type = string }
variable "node_instance_types" { type = list(string); default = ["t3.small"] }
variable "desired_nodes"       { type = number; default = 1 }
variable "min_nodes"           { type = number; default = 1 }
variable "max_nodes"           { type = number; default = 2 }
variable "allowed_cidr_blocks" { type = list(string); default = ["0.0.0.0/0"] }
variable "tags"                { type = map(string); default = {} }
