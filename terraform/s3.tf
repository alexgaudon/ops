resource "aws_s3_bucket_lifecycle_configuration" "backup_docker" {
  bucket = "amgau.backup.docker"

  rule {
    id     = "expire_after_30_days"
    status = "Enabled"

    expiration {
      days = 30
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "homelab" {
  bucket = "amgau.homelab"

  rule {
    id     = "expire_after_30_days"
    status = "Enabled"

    expiration {
      days = 30
    }
  }
}