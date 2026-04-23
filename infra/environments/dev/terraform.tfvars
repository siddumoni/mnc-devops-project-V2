# ─────────────────────────────────────────────────────────────────────────────
# DEV LAB — terraform.tfvars
#
# Cost-optimised single environment for learning.
# infra.ps1 bootstrap will patch aws_account_id and jenkins_ami_id
# automatically before first terraform init.
#
# Key differences from MNC production:
#   - No NAT Gateways  (EKS nodes in public subnets)
#   - SPOT instances   (t3.small nodes — cheapest viable)
#   - Single AZ RDS    (no Multi-AZ)
#   - 1 node normally  (Cluster Autoscaler adds 2nd only when needed)
# ─────────────────────────────────────────────────────────────────────────────

project_name   = "mnc-app"
environment    = "dev"
aws_region     = "ap-south-1"
aws_account_id = "204803374292" # patched by infra.ps1 bootstrap

# ── Networking ────────────────────────────────────────────────────────────
vpc_cidr             = "10.10.0.0/16"
public_subnet_cidrs  = ["10.10.1.0/24", "10.10.2.0/24"]   # Jenkins + EKS nodes here
private_subnet_cidrs = ["10.10.10.0/24", "10.10.11.0/24"] # RDS only — no internet needed
availability_zones   = ["ap-south-1a", "ap-south-1b"]

# ── Access ────────────────────────────────────────────────────────────────
ec2_key_name        = "mnc-app-keypair"
allowed_cidr_blocks = ["0.0.0.0/0"] # Open for lab convenience

# ── Jenkins EC2 ───────────────────────────────────────────────────────────
# t3.large required: Jenkins + Maven + SonarQube Docker need ~5GB RAM together
jenkins_ami_id        = "ami-0c95fa15b20f5400e" # patched by infra.ps1 bootstrap
jenkins_instance_type = "t3.large"

# ── EKS ───────────────────────────────────────────────────────────────────
kubernetes_version  = "1.35"
node_instance_types = ["t3.small"] # 2 vCPU, 2GB — smallest viable for app pods
desired_nodes       = 1            # Start with 1, Cluster Autoscaler adds 2nd if needed
min_nodes           = 1
max_nodes           = 2 # Max 2 to cap cost

# ── RDS ───────────────────────────────────────────────────────────────────
db_username       = "appuser"
db_instance_class = "db.t3.micro"
db_storage        = 20

# ── ACM ───────────────────────────────────────────────────────────────────
# Leave empty for lab — Jenkins ALB runs on HTTP only
# For HTTPS: set this to your ACM certificate ARN and re-apply
acm_certificate_arn = ""
