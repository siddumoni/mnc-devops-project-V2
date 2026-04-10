variable "project_name" { type = string }
variable "environment" { type = string }
variable "vpc_id" { type = string }
variable "vpc_cidr" { type = string }
variable "public_subnet_id" { type = string }
variable "public_subnet_ids" { type = list(string) }
variable "availability_zone" { type = string }
variable "ami_id" { type = string }
variable "instance_type" {
  type    = string
  default = "t3.large"
}

variable "ec2_key_name" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "aws_account_id" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "allowed_cidr_blocks" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}

variable "acm_certificate_arn" {
  type    = string
  default = ""
}

variable "tags" {
  type    = map(string)
  default = {}
}
