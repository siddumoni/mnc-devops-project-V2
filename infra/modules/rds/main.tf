# RDS — stays in private subnets (no internet needed, security isolation)
resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-${var.environment}-db-subnet-group"
  subnet_ids = var.private_subnet_ids

  tags = merge(var.tags, { Name = "${var.project_name}-${var.environment}-db-subnet-group" })
}

resource "aws_security_group" "rds" {
  name        = "${var.project_name}-${var.environment}-rds-sg"
  description = "RDS MySQL - inbound from EKS nodes and Jenkins only"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [var.eks_node_sg_id]
    description     = "MySQL from EKS pods"
  }

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [var.jenkins_sg_id]
    description     = "MySQL from Jenkins (Flyway migrations)"
  }

  tags = merge(var.tags, { Name = "${var.project_name}-${var.environment}-rds-sg" })
}

resource "aws_db_parameter_group" "main" {
  name   = "${var.project_name}-${var.environment}-mysql8"
  family = "mysql8.0"

  parameter {
    name  = "slow_query_log"
    value = "1"
  }

  parameter {
    name  = "long_query_time"
    value = "2"
  }

  parameter {
    name  = "character_set_server"
    value = "utf8mb4"
  }

  parameter {
    name  = "collation_server"
    value = "utf8mb4_unicode_ci"
  }

  tags = var.tags
}

resource "aws_db_instance" "main" {
  identifier     = "${var.project_name}-${var.environment}-mysql"
  engine         = "mysql"
  engine_version = "8.0"
  instance_class = var.db_instance_class

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.allocated_storage * 2

  db_name  = replace("${var.project_name}_${var.environment}", "-", "_")
  username = var.db_username
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.main.name

  backup_retention_period = 3 # Short for lab
  backup_window           = "03:00-04:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"
  deletion_protection     = false # Lab: allow easy deletion
  skip_final_snapshot     = true  # Lab: no final snapshot needed
  storage_encrypted       = true
  multi_az                = false # Lab: single-AZ (Multi-AZ in prod)

  tags = merge(var.tags, { Name = "${var.project_name}-${var.environment}-mysql" })
}
