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
resource "aws_lambda_function" "analytics_processor" {
  filename      = "../deployment.zip"
  function_name = "url-analytics-processor-${var.environment}"
  role          = aws_iam_role.analytics_executor.arn
  handler       = "dist/handlers/stats-handler.handler"
  runtime       = "nodejs20.x"
  timeout       = 30
  memory_size   = 256

  source_code_hash = filebase64sha256("../deployment.zip")

  environment {
    variables = {
      ANALYTICS_TABLE = aws_dynamodb_table.url_analytics.name
      URLS_TABLE      = var.urls_table_name
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_basic_execution
  ]
}

# IAM Role for Lambda
resource "aws_iam_role" "analytics_executor" {
  name = "url-analytics-executor-${var.environment}"

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

# IAM Policies for Lambda
resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.analytics_executor.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "analytics_data_access" {
  name = "analytics-data-access-${var.environment}"
  role = aws_iam_role.analytics_executor.id

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
          aws_dynamodb_table.url_analytics.arn,
          "${aws_dynamodb_table.url_analytics.arn}/index/*",
          "arn:aws:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${var.urls_table_name}"
        ]
      }
    ]
  })
}

# CloudWatch Log Groups
resource "aws_cloudwatch_log_group" "analytics_logs" {
  name              = "/aws/lambda/url-analytics-processor-${var.environment}"
  retention_in_days = 14

  tags = {
    Environment = var.environment
    Project     = "url-shortener"
  }
}

resource "aws_cloudwatch_log_group" "api_gateway_logs" {
  name              = "/aws/apigateway/url-analytics-api-${var.environment}"
  retention_in_days = 7

  tags = {
    Environment = var.environment
    Project     = "url-shortener"
  }
}

# IAM Role for API Gateway Logging
resource "aws_iam_role" "api_logging_role" {
  name = "api-gateway-logging-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "apigateway.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "api_logging_policy" {
  role       = aws_iam_role.api_logging_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}

# API Gateway Account
resource "aws_api_gateway_account" "analytics_api_account" {
  cloudwatch_role_arn = aws_iam_role.api_logging_role.arn
}

# API Gateway HTTP API
resource "aws_apigatewayv2_api" "analytics_api" {
  name          = "url-analytics-api-${var.environment}"
  protocol_type = "HTTP"
  
  # CORS se maneja en Lambda
}

resource "aws_apigatewayv2_stage" "analytics_stage" {
  api_id      = aws_apigatewayv2_api.analytics_api.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gateway_logs.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      protocol       = "$context.protocol"
      responseLength = "$context.responseLength"
    })
  }

  depends_on = [
    aws_cloudwatch_log_group.api_gateway_logs,
    aws_api_gateway_account.analytics_api_account
  ]

  tags = {
    Environment = var.environment
    Project     = "url-shortener"
  }
}

resource "aws_apigatewayv2_integration" "analytics_integration" {
  api_id             = aws_apigatewayv2_api.analytics_api.id
  integration_type   = "AWS_PROXY"
  integration_method = "POST"
  integration_uri    = aws_lambda_function.analytics_processor.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "get_analytics" {
  api_id    = aws_apigatewayv2_api.analytics_api.id
  route_key = "GET /stats/{code}"
  target    = "integrations/${aws_apigatewayv2_integration.analytics_integration.id}"
}

resource "aws_apigatewayv2_route" "analytics_options" {
  api_id    = aws_apigatewayv2_api.analytics_api.id
  route_key = "OPTIONS /stats/{code}"
  target    = "integrations/${aws_apigatewayv2_integration.analytics_integration.id}"
}

# Lambda Permission
resource "aws_lambda_permission" "api_gateway_invoke" {
  statement_id  = "AllowAPIGatewayInvocation"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.analytics_processor.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.analytics_api.execution_arn}/*/*"
}

# DynamoDB Table
resource "aws_dynamodb_table" "url_analytics" {
  name         = "url-analytics-data-${var.environment}"
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
    name            = "AnalyticsDateIndex"
    hash_key        = "code"
    range_key       = "lastUpdated"
    projection_type = "ALL"
  }

  tags = {
    Environment = var.environment
    Project     = "url-shortener"
  }
}

# Data Sources
data "aws_caller_identity" "current" {}

# Outputs
output "api_gateway_endpoint" {
  description = "URL of the API Gateway"
  value       = aws_apigatewayv2_api.analytics_api.api_endpoint
}

output "analytics_processor_name" {
  description = "Name of the Lambda function"
  value       = aws_lambda_function.analytics_processor.function_name
}

output "analytics_processor_arn" {
  description = "ARN of the Lambda function"
  value       = aws_lambda_function.analytics_processor.arn
}

output "analytics_table_name" {
  description = "Name of the DynamoDB analytics table"
  value       = aws_dynamodb_table.url_analytics.name
}

output "analytics_table_arn" {
  description = "ARN of the DynamoDB analytics table"
  value       = aws_dynamodb_table.url_analytics.arn
}