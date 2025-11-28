variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "urls_table_name" {
  description = "Name of the existing URLs table"
  type        = string
  default     = "shortener-dynamo-table"
}

variable "lambda_zip_path" {
  description = "Path to the Lambda deployment package"
  type        = string
  default     = "../deployment.zip"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "production"
}