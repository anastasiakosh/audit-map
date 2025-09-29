output "sqs_queue_url" {
  value = aws_sqs_queue.audit.id
}

output "sqs_queue_arn" {
  value = aws_sqs_queue.audit.arn
}

output "s3_bucket" {
  value = aws_s3_bucket.raw.bucket
}

output "db_endpoint" {
  value = aws_db_instance.audit_db.address
}

output "db_port" {
  value = aws_db_instance.audit_db.port
}

output "db_username" {
  value = var.db_username
}

output "secret_arn" {
  value = aws_secretsmanager_secret.db.arn
}

