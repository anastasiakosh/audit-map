# ---------------------------
# main.tf - исправленный для AWS Provider 5.x
# ---------------------------

resource "random_id" "bucket" {
  byte_length = 4
}

resource "random_password" "db" {
  length             = 16
  special            = true
}

# ---------------------------
# S3 bucket (raw JSON backup)
# ---------------------------
resource "aws_s3_bucket" "raw" {
  bucket        = "${var.project_name}-raw-${random_id.bucket.hex}"
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "raw_versioning" {
  bucket = aws_s3_bucket.raw.id
  versioning_configuration {
    status = "Enabled"
  }
}

# ---------------------------
# SQS queue
# ---------------------------
resource "aws_sqs_queue" "audit" {
  name = "${var.project_name}-queue"
}

# ---------------------------
# Secrets Manager - store DB credentials
# ---------------------------
resource "aws_secretsmanager_secret" "db" {
  name = "${var.project_name}-db-creds"
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id     = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db.result
  })
}

# ---------------------------
# Security group for RDS (demo)
# ---------------------------
resource "aws_security_group" "rds_sg" {
  name        = "${var.project_name}-rds-sg"
  description = "Allow Postgres inbound for demo (restrict in prod)"

  ingress {
    description = "Postgres"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ---------------------------
# RDS Postgres
# ---------------------------
resource "aws_db_instance" "audit_db" {
  identifier             = "${var.project_name}-db"
  engine                 = "postgres"
  instance_class         = "db.t3.micro"
  allocated_storage      = 20
  db_name                = var.db_name        # исправлено
  username               = var.db_username
  password               = random_password.db.result
  publicly_accessible    = false
  skip_final_snapshot    = true
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
}

# ---------------------------
# IAM role for Lambda
# ---------------------------
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${var.project_name}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "${var.project_name}-lambda-policy"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow",
        Action = [
          "s3:PutObject",
          "s3:PutObjectAcl"
        ],
        Resource = "${aws_s3_bucket.raw.arn}/*"
      },
      {
        Effect = "Allow",
        Action = [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes"
      ],
      Resource = aws_sqs_queue.audit.arn
    }
  ]
})
}

# ---------------------------
# Lambda function
# ---------------------------
resource "aws_lambda_function" "auditor" {
  filename         = "${path.module}/lambda.zip"
  function_name    = "${var.project_name}-writer"
  role             = aws_iam_role.lambda.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.10"
  source_code_hash = filebase64sha256("${path.module}/lambda.zip")

  environment {
    variables = {
      SECRET_ARN = aws_secretsmanager_secret.db.arn
      DB_HOST    = aws_db_instance.audit_db.address
      DB_PORT    = "5432"
      DB_NAME    = var.db_name
      S3_BUCKET  = aws_s3_bucket.raw.bucket
    }
  }

  depends_on = [aws_iam_role_policy.lambda_policy]
}

# ---------------------------
# Event source mapping SQS -> Lambda
# ---------------------------
resource "aws_lambda_event_source_mapping" "sqs" {
  event_source_arn = aws_sqs_queue.audit.arn
  function_name    = aws_lambda_function.auditor.arn
  enabled          = true
  batch_size       = 10
}

