# The app team's layer: resources that belong to the application, not the platform.

resource "aws_ecr_repository" "app" {
  name = var.repository_name

  # MUTABLE so the pipeline can move the `latest` tag. Versioned tags (1.0.0-<sha>) never change.
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the ${var.images_to_keep} most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = var.images_to_keep
      }
      action = { type = "expire" }
    }]
  })
}
