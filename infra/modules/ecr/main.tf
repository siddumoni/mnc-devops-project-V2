locals {
  repositories = ["frontend", "backend"]
}

resource "aws_ecr_repository" "app" {
  for_each             = toset(local.repositories)
  name                 = "${var.project_name}/${each.key}"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration { scan_on_push = true }
  encryption_configuration    { encryption_type = "AES256" }

  # ECR repositories are NEVER destroyed — they hold your built images.
  # infra.ps1 explicitly excludes ECR from destroy operations.
  lifecycle { prevent_destroy = true }

  tags = merge(var.tags, { Name = "${var.project_name}-${each.key}" })
}

resource "aws_ecr_lifecycle_policy" "app" {
  for_each   = aws_ecr_repository.app
  repository = each.value.name

  policy = jsonencode({
    rules = [
      { rulePriority = 1; description = "Remove untagged images after 1 day"
        selection = { tagStatus = "untagged"; countType = "sinceImagePushed"; countUnit = "days"; countNumber = 1 }
        action = { type = "expire" }
      },
      { rulePriority = 2; description = "Keep only last 20 tagged images"
        selection = { tagStatus = "tagged"; tagPrefixList = ["sha-","dev-"]; countType = "imageCountMoreThan"; countNumber = 20 }
        action = { type = "expire" }
      }
    ]
  })
}
