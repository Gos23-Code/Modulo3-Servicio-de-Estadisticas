terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Lambda Function
resource "aws_lambda_function" "stats_handler" {
  filename      = "../deployment.zip"
  function_name = "url-shortener-stats-${var.environment}"
  role          = aws_iam_role.lambda_role.arn
  handler       = "dist/handlers/stats-handler.handler"
  runtime       = "nodejs20.x"
  timeout       = 30
  memory_size   = 256

  source_code_hash = filebase64sha256("../deployment.zip")

  environment {
    variables = {
      STATS_TABLE = aws_dynamodb_table.stats.name
      URLS_TABLE  = var.urls_table_name
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_logs
  ]
}

# IAM Role for Lambda
resource "aws_iam_role" "lambda_role" {
  name = "url-shortener-stats-lambda-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

# IAM Policies
resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "dynamodb_access" {
  name = "dynamodb-access-${var.environment}"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:UpdateItem",  
          "dynamodb:Query",
          "dynamodb:Scan",
          "dynamodb:PutItem"      
        ]
        Resource = [
          aws_dynamodb_table.stats.arn,
          "arn:aws:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${var.urls_table_name}"
        ]
      }
    ]
  })
}

# API Gateway - SIN CORS CONFIGURATION
resource "aws_apigatewayv2_api" "stats_api" {
  name          = "url-shortener-stats-api-${var.environment}"
  protocol_type = "HTTP"
  # ⬇️ REMOVER completamente cors_configuration
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.stats_api.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gw.arn
    format = jsonencode({
      requestId = "$context.requestId",
      ip = "$context.identity.sourceIp",
      requestTime = "$context.requestTime",
      httpMethod = "$context.httpMethod",
      routeKey = "$context.routeKey",
      status = "$context.status",
      protocol = "$context.protocol",
      responseLength = "$context.responseLength"
    })
  }
}

resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id             = aws_apigatewayv2_api.stats_api.id
  integration_type   = "AWS_PROXY"
  integration_method = "POST"
  integration_uri    = aws_lambda_function.stats_handler.invoke_arn
}

resource "aws_apigatewayv2_route" "get_stats" {
  api_id    = aws_apigatewayv2_api.stats_api.id
  route_key = "GET /stats/{code}"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

resource "aws_apigatewayv2_route" "options" {
  api_id    = aws_apigatewayv2_api.stats_api.id
  route_key = "OPTIONS /stats/{code}"
  target    = "integraciones/${aws_apigatewayv2_integration.lambda_integration.id}"
}

# Lambda Permission
resource "aws_lambda_permission" "api_gw" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.stats_handler.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.stats_api.execution_arn}/*/*"
}

# DynamoDB Table
resource "aws_dynamodb_table" "stats" {
  name         = "url-shortener-stats-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "code"
  range_key    = "lastUpdated"

  attribute {
    name = "code"
    type = "S"
  }

  attribute {
    name = "lastUpdated"
    type = "S"
  }

  global_secondary_index {
    name            = "DateIndex"
    hash_key        = "code"
    range_key       = "lastUpdated"
    projection_type = "ALL"
    read_capacity   = 5
    write_capacity  = 5
  }

  tags = {
    Environment = var.environment
    Project     = "url-shortener"
  }
}

# CloudWatch Log Groups
resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/${aws_lambda_function.stats_handler.function_name}"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "api_gw" {
  name              = "/aws/apigateway/${aws_apigatewayv2_api.stats_api.name}"
  retention_in_days = 7
}

data "aws_caller_identity" "current" {}

# Outputs
output "api_gateway_url" {
  description = "URL of the API Gateway"
  value       = "${aws_apigatewayv2_api.stats_api.api_endpoint}/"
}

output "lambda_function_name" {
  description = "Name of the Lambda function"
  value       = aws_lambda_function.stats_handler.function_name
}

output "dynamodb_table_name" {
  description = "Name of the DynamoDB table"
  value       = aws_dynamodb_table.stats.name
}