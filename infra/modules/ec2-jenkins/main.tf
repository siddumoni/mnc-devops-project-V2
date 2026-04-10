# ─────────────────────────────────────────────────────────────────────────────
# EC2-JENKINS MODULE — Lab Edition
#
# Key feature: Jenkins home + SonarQube data live on a dedicated EBS volume.
# That EBS volume is NOT managed by Terraform lifecycle — the infra.ps1 script
# handles its preservation across destroy/recreate cycles manually.
# This means all your Jenkins config, plugins, credentials, jobs, and
# SonarQube project data survive every destroy/recreate.
# ─────────────────────────────────────────────────────────────────────────────

# ── IAM Role for Jenkins EC2 ─────────────────────────────────────────────
resource "aws_iam_role" "jenkins" {
  name = "${var.project_name}-jenkins-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_instance_profile" "jenkins" {
  name = "${var.project_name}-jenkins-profile"
  role = aws_iam_role.jenkins.name
}

resource "aws_iam_policy" "jenkins" {
  name        = "${var.project_name}-jenkins-policy"
  description = "Permissions Jenkins needs to build and deploy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ECRAuth"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "ECRPushPull"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:GetRepositoryPolicy",
          "ecr:DescribeRepositories",
          "ecr:ListImages",
          "ecr:DescribeImages",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage"
        ]
        Resource = "arn:aws:ecr:${var.aws_region}:${var.aws_account_id}:repository/${var.project_name}/*"
      },
      {
        Sid    = "EKSAccess"
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:ListClusters"
        ]
        Resource = "*"
      },
      {
        Sid    = "SSMParameters"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath",
          "ssm:PutParameter"
        ]
        Resource = "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:parameter/${var.project_name}/*"
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      },
      {
        Sid      = "STS"
        Effect   = "Allow"
        Action   = ["sts:GetCallerIdentity"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "jenkins" {
  policy_arn = aws_iam_policy.jenkins.arn
  role       = aws_iam_role.jenkins.name
}

resource "aws_iam_role_policy_attachment" "jenkins_ssm" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.jenkins.name
}

# ── Security Group — Jenkins EC2 ─────────────────────────────────────────
resource "aws_security_group" "jenkins" {
  name        = "${var.project_name}-jenkins-sg"
  description = "Jenkins master EC2"
  vpc_id      = var.vpc_id

  # Jenkins UI — open to all (lab convenience, production would restrict to VPN IP)
  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
    description = "Jenkins UI"
  }

  # SonarQube — accessible for SSM tunnel
  ingress {
    from_port   = 9000
    to_port     = 9000
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
    description = "SonarQube UI"
  }

  # SSH — from VPC only (use SSM Session Manager instead of direct SSH)
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "SSH from VPC only"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "All outbound — Jenkins needs GitHub, ECR, EKS, SonarQube, DockerHub"
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-jenkins-sg"
  })
}

# ── Jenkins ALB Security Group ────────────────────────────────────────────
resource "aws_security_group" "jenkins_alb" {
  name        = "${var.project_name}-jenkins-alb-sg"
  description = "ALB for Jenkins UI"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
    description = "HTTP"
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
    description = "HTTPS"
  }

  egress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "Forward to Jenkins"
  }

  tags = merge(var.tags, { Name = "${var.project_name}-jenkins-alb-sg" })
}

# ── Persistent EBS Volume for Jenkins Home + SonarQube Data ───────────────
# CRITICAL: This resource has prevent_destroy = true and is intentionally
# NOT included in the destroy target list in infra.ps1.
# Your Jenkins config, plugins, credentials, jobs, and SonarQube data
# all live here and survive every destroy/recreate cycle.
resource "aws_ebs_volume" "jenkins_home" {
  availability_zone = var.availability_zone
  size              = 30 # GB — Jenkins home + SonarQube data + Maven cache
  type              = "gp3"
  encrypted         = true

  # IMPORTANT: prevent_destroy stops accidental deletion via terraform destroy
  lifecycle {
    prevent_destroy = true
    # ignore_changes ensures Terraform does not try to replace this volume
    # if the AZ or size is changed in tfvars
    ignore_changes = [availability_zone, size]
  }

  tags = merge(var.tags, {
    Name        = "${var.project_name}-jenkins-home"
    Persistent  = "true"
    Description = "Jenkins home dir + SonarQube data — DO NOT DELETE"
  })
}

resource "aws_volume_attachment" "jenkins_home" {
  device_name = "/dev/xvdf"
  volume_id   = aws_ebs_volume.jenkins_home.id
  instance_id = aws_instance.jenkins.id
  # Skip destroy on volume attachment — infra.ps1 handles detach manually
  skip_destroy = true
}

# ── Jenkins EC2 Instance ──────────────────────────────────────────────────
resource "aws_instance" "jenkins" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  key_name               = var.ec2_key_name
  subnet_id              = var.public_subnet_id
  vpc_security_group_ids = [aws_security_group.jenkins.id]
  iam_instance_profile   = aws_iam_instance_profile.jenkins.name

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  user_data = base64encode(templatefile("${path.module}/userdata.sh", {
    project_name   = var.project_name
    aws_region     = var.aws_region
    cluster_name   = var.cluster_name
    sonarqube_port = 9000
  }))

  tags = merge(var.tags, {
    Name = "${var.project_name}-jenkins-master"
    Role = "jenkins"
  })
}

# ── ALB for Jenkins ───────────────────────────────────────────────────────
resource "aws_lb" "jenkins" {
  name               = "${var.project_name}-jenkins-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.jenkins_alb.id]
  subnets            = var.public_subnet_ids

  enable_deletion_protection = false # Lab: allow easy deletion

  tags = var.tags
}

resource "aws_lb_target_group" "jenkins" {
  name     = "${var.project_name}-jenkins-tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  health_check {
    path                = "/login"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 10
  }

  tags = var.tags
}

resource "aws_lb_target_group_attachment" "jenkins" {
  target_group_arn = aws_lb_target_group.jenkins.arn
  target_id        = aws_instance.jenkins.id
  port             = 8080
}

resource "aws_lb_listener" "jenkins_http" {
  load_balancer_arn = aws_lb.jenkins.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.jenkins.arn
  }
}

# HTTPS listener — only created when ACM cert ARN is provided
resource "aws_lb_listener" "jenkins_https" {
  count             = var.acm_certificate_arn != "" ? 1 : 0
  load_balancer_arn = aws_lb.jenkins.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.jenkins.arn
  }
}
