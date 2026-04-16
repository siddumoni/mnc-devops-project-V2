variable "project_name" { type = string }
variable "environment" { type = string }
variable "aws_region" {
  type    = string
  default = "ap-south-1"
}
variable "aws_account_id" { type = string }
variable "vpc_cidr" { type = string }
variable "public_subnet_cidrs" { type = list(string) }
variable "private_subnet_cidrs" { type = list(string) }
variable "availability_zones" { type = list(string) }
variable "ec2_key_name" { type = string }
variable "jenkins_ami_id" { type = string }
variable "jenkins_instance_type" {
  type    = string
  default = "t3.large"
}
variable "allowed_cidr_blocks" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}
variable "kubernetes_version" {
  type    = string
  default = "1.32"
}

variable "node_instance_types" {
  type    = list(string)
  default = ["t3.small"]
}

variable "desired_nodes" {
  type    = number
  default = 1
}

variable "min_nodes" {
  type    = number
  default = 1
}

variable "max_nodes" {
  type    = number
  default = 2
}

variable "db_username" {
  type    = string
  default = "appuser"
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "db_instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "db_storage" {
  type    = number
  default = 20
}

variable "acm_certificate_arn" {
  type    = string
  default = ""
}


variable "enable_kubernetes_resources" {
  type    = bool
  default = false
}
