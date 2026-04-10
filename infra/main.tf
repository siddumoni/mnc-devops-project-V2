# ─────────────────────────────────────────────────────────────────────────────
# ROOT MODULE — infra/main.tf
# Called as a module by environments/dev/main.tf
# No terraform{} block here — that lives in the environment folder only.
# ─────────────────────────────────────────────────────────────────────────────

locals {
  cluster_name = "${var.project_name}-${var.environment}-cluster"
  common_tags  = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

module "vpc" {
  source               = "./modules/vpc"
  project_name         = var.project_name
  environment          = var.environment
  cluster_name         = local.cluster_name
  vpc_cidr             = var.vpc_cidr
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  availability_zones   = var.availability_zones
  tags                 = local.common_tags
}

module "jenkins" {
  source              = "./modules/ec2-jenkins"
  project_name        = var.project_name
  environment         = var.environment
  vpc_id              = module.vpc.vpc_id
  vpc_cidr            = module.vpc.vpc_cidr
  public_subnet_id    = module.vpc.public_subnet_ids[0]
  public_subnet_ids   = module.vpc.public_subnet_ids
  availability_zone   = var.availability_zones[0]
  ami_id              = var.jenkins_ami_id
  instance_type       = var.jenkins_instance_type
  ec2_key_name        = var.ec2_key_name
  aws_region          = var.aws_region
  aws_account_id      = var.aws_account_id
  cluster_name        = local.cluster_name
  allowed_cidr_blocks = var.allowed_cidr_blocks
  acm_certificate_arn = var.acm_certificate_arn
  tags                = local.common_tags
}

module "ecr" {
  source       = "./modules/ecr"
  project_name = var.project_name
  tags         = local.common_tags
}

# ALB Security Group — defined before EKS so alb_sg_id can be passed to node SG
resource "aws_security_group" "alb" {
  name        = "${var.project_name}-${var.environment}-alb-sg"
  description = "Application Load Balancer for app traffic"
  vpc_id      = module.vpc.vpc_id

  ingress { from_port = 80;  to_port = 80;  protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"]; description = "HTTP" }
  ingress { from_port = 443; to_port = 443; protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"]; description = "HTTPS" }
  egress  { from_port = 0;   to_port = 0;   protocol = "-1";  cidr_blocks = ["0.0.0.0/0"] }

  tags = merge(local.common_tags, { Name = "${var.project_name}-${var.environment}-alb-sg" })
}

module "eks" {
  source              = "./modules/eks"
  project_name        = var.project_name
  environment         = var.environment
  cluster_name        = local.cluster_name
  kubernetes_version  = var.kubernetes_version
  vpc_id              = module.vpc.vpc_id
  public_subnet_ids   = module.vpc.public_subnet_ids
  jenkins_sg_id       = module.jenkins.jenkins_security_group_id
  alb_sg_id           = aws_security_group.alb.id
  jenkins_role_arn    = module.jenkins.jenkins_role_arn
  node_instance_types = var.node_instance_types
  desired_nodes       = var.desired_nodes
  min_nodes           = var.min_nodes
  max_nodes           = var.max_nodes
  allowed_cidr_blocks = var.allowed_cidr_blocks
  tags                = local.common_tags
}

module "rds" {
  source             = "./modules/rds"
  project_name       = var.project_name
  environment        = var.environment
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  eks_node_sg_id     = module.eks.node_security_group_id
  jenkins_sg_id      = module.jenkins.jenkins_security_group_id
  db_username        = var.db_username
  db_password        = var.db_password
  db_instance_class  = var.db_instance_class
  allocated_storage  = var.db_storage
  tags               = local.common_tags
}

# Kubernetes namespace — created in Pass 2 (after EKS is healthy)
resource "kubernetes_namespace" "env" {
  metadata {
    name = var.environment
    labels = {
      environment = var.environment
      managed-by  = "terraform"
    }
  }
  depends_on = [module.eks]
}

# SSM Parameters — Jenkins reads these at runtime
resource "aws_ssm_parameter" "db_host" {
  name  = "/${var.project_name}/${var.environment}/db/host"
  type  = "String"
  value = module.rds.db_host
  tags  = local.common_tags
}

resource "aws_ssm_parameter" "db_name" {
  name  = "/${var.project_name}/${var.environment}/db/name"
  type  = "String"
  value = module.rds.db_name
  tags  = local.common_tags
}

resource "aws_ssm_parameter" "db_password" {
  name  = "/${var.project_name}/${var.environment}/db/password"
  type  = "SecureString"
  value = var.db_password
  tags  = local.common_tags
}

resource "aws_ssm_parameter" "ecr_registry" {
  name  = "/${var.project_name}/ecr/registry"
  type  = "String"
  value = "${var.aws_account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
  tags  = local.common_tags
}
