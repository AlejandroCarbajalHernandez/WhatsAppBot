# 1. Definición del Proveedor
provider "aws" {
  region = var.aws_region # Usamos la variable definida en variables.tf
}

# 2. Data source para obtener tu ID de cuenta automáticamente
data "aws_caller_identity" "current" {}

# 3. Repositorio de Docker (ECR)
resource "aws_ecr_repository" "repo" {
  name                 = "${var.client_name}-bot"
  image_tag_mutability = "MUTABLE"
  force_delete         = true 
}

# 4. Automatización de Docker (Build & Push)
resource "null_resource" "docker_push" {
  triggers = {
    python_code = md5(file("../src/app.py"))
    dockerfile  = md5(file("../Dockerfile"))
  }

  provisioner "local-exec" {
    command = <<EOF
      aws ecr get-login-password --region ${var.aws_region} | docker login --username AWS --password-stdin ${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com
      
      docker buildx build --platform linux/amd64 --provenance=false -t ${var.client_name}-bot:latest ../
      
      docker tag ${var.client_name}-bot:latest ${aws_ecr_repository.repo.repository_url}:latest
      docker push ${aws_ecr_repository.repo.repository_url}:latest
    EOF
  }
}

# 5. Tabla de Memoria (DynamoDB)
resource "aws_dynamodb_table" "history" {
  name           = "${var.client_name}-chat-history"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "SessionId"

  attribute {
    name = "SessionId"
    type = "S"
  }
}

# 6. La Función Lambda
resource "aws_lambda_function" "whatsapp_bot" {
  function_name = "${var.client_name}-handler"
  role          = aws_iam_role.lambda_role.arn
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.repo.repository_url}:latest"
  timeout       = 30 
  memory_size   = 512
  architectures = ["x86_64"]

  environment {
    variables = {
      TABLE_NAME             = aws_dynamodb_table.history.name
      WHATSAPP_TOKEN         = var.whatsapp_token
      PHONE_NUMBER_ID        = var.phone_number_id
      VERIFY_TOKEN           = var.verify_token
      API_VERSION            = var.api_version
      RECIPIENT_PHONE_NUMBER = var.recipient_phone_number
    }
  }

  depends_on = [null_resource.docker_push]
}

# 7. Permisos (IAM)
resource "aws_iam_role" "lambda_role" {
  name = "${var.client_name}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_policy" "lambda_policy" {
  name = "${var.client_name}-policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
        Effect = "Allow", Resource = "*"
      },
      {
        Action = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:UpdateItem"],
        Effect = "Allow", Resource = aws_dynamodb_table.history.arn
      },
      {
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
        Effect = "Allow", Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "attach" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_policy.arn
}

# 8. URL Pública para Meta (Webhook)
resource "aws_lambda_function_url" "url" {
  function_name      = aws_lambda_function.whatsapp_bot.function_name
  authorization_type = "NONE"
}

