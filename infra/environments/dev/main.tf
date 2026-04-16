# environments/dev/main.tf
# This is where you run terraform init and terraform apply from.
# It calls the root module at ../../ and owns the S3 backend config.

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.30"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.24"
    }
  }

  backend "s3" {
    # infra.ps1 bootstrap patches this bucket name automatically
    bucket         = "mnc-app-v2-terraform-state-204803374292"
    key            = "environments/dev/terraform.tfstate"
    region         = "ap-south-1"
    encrypt        = true
    dynamodb_table = "terraform-state-lock"
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_eks_cluster" "dev" {
  count = var.enable_kubernetes_resources ? 1 : 0
  name  = "${var.project_name}-${var.environment}-cluster"
}

provider "kubernetes" {
 # Keep provider configuration import-safe:
  # - Pass 1/import runs with enable_kubernetes_resources=false and uses a dummy
  #   endpoint so Terraform can configure the provider without kubeconfig.
  # - Pass 2 sets enable_kubernetes_resources=true, loads the real EKS endpoint
  #   from data.aws_eks_cluster.dev, and uses aws eks get-token for auth.
  host = var.enable_kubernetes_resources ? data.aws_eks_cluster.dev[0].endpoint : "https://127.0.0.1"

  cluster_ca_certificate = var.enable_kubernetes_resources ? base64decode(data.aws_eks_cluster.dev[0].certificate_authority[0].data) : null

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", "${var.project_name}-${var.environment}-cluster", "--region", var.aws_region]
  }
}

module "dev" {
  source = "../../"

  project_name          = var.project_name
  environment           = var.environment
  aws_region            = var.aws_region
  aws_account_id        = var.aws_account_id
  vpc_cidr              = var.vpc_cidr
  public_subnet_cidrs   = var.public_subnet_cidrs
  private_subnet_cidrs  = var.private_subnet_cidrs
  availability_zones    = var.availability_zones
  ec2_key_name          = var.ec2_key_name
  jenkins_ami_id        = var.jenkins_ami_id
  jenkins_instance_type = var.jenkins_instance_type
  allowed_cidr_blocks   = var.allowed_cidr_blocks
  kubernetes_version    = var.kubernetes_version
  node_instance_types   = var.node_instance_types
  desired_nodes         = var.desired_nodes
  min_nodes             = var.min_nodes
  max_nodes             = var.max_nodes
  db_username           = var.db_username
  db_password           = var.db_password
  db_instance_class     = var.db_instance_class
  db_storage            = var.db_storage
  acm_certificate_arn   = var.acm_certificate_arn
  enable_kubernetes_resources = var.enable_kubernetes_resources
}

# ── Pass-through outputs ──────────────────────────────────────────────────
output "vpc_id" { value = module.dev.vpc_id }
output "cluster_name" { value = module.dev.cluster_name }
output "cluster_endpoint" { value = module.dev.cluster_endpoint }
output "cluster_ca_certificate" {
  value     = module.dev.cluster_ca_certificate
  sensitive = true
}
output "jenkins_alb_dns" { value = module.dev.jenkins_alb_dns }
output "jenkins_public_ip" { value = module.dev.jenkins_public_ip }
output "jenkins_ebs_volume_id" { value = module.dev.jenkins_ebs_volume_id }
output "sonarqube_url" { value = module.dev.sonarqube_url }
output "db_endpoint" { value = module.dev.db_endpoint }
output "db_host" { value = module.dev.db_host }
output "ecr_repository_urls" { value = module.dev.ecr_repository_urls }
output "alb_controller_role_arn" { value = module.dev.alb_controller_role_arn }
