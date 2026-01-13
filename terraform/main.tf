# 1. Definición del Proveedor
provider "aws" {
  region = var.aws_region
}
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0" # O la versión específica que soporte S3 Vectors
    }
  }
}

# 2. Data source y variables locales
data "aws_caller_identity" "current" {}

resource "random_id" "suffix" {
  byte_length = 4
}

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

# 5. Tabla de Memoria (DynamoDB) - LA MANTENEMOS
resource "aws_dynamodb_table" "history" {
  name           = "${var.client_name}-chat-history"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "SessionId"

  attribute {
    name = "SessionId"
    type = "S"
  }
}

# ---------------------------------------------------------
# NUEVA SECCIÓN: INFRAESTRUCTURA DE CONOCIMIENTO (RAG)
# ---------------------------------------------------------

# 6. Almacenamiento de PDF (S3 Standard)
resource "aws_s3_bucket" "raw_data_bucket" {
  bucket        = "ahcloud-raw-docs-${random_id.suffix.hex}"
  force_destroy = true
}

resource "aws_s3_object" "business_pdf" {
  bucket = aws_s3_bucket.raw_data_bucket.id
  key    = "conocimiento-negocio.pdf"
  source = "${path.module}/docs/conocimiento-negocio.pdf"
  etag   = filemd5("${path.module}/docs/conocimiento-negocio.pdf")
}

# 7. Crear el Bucket de Vectores
resource "aws_s3vectors_vector_bucket" "lujo_vector_store" {
  vector_bucket_name = "ahcloud-vectors-${random_id.suffix.hex}"
  
  encryption_configuration {
    sse_type = "AES256"
  }
}

# Crear el Índice Vectorial (Corregido sin bloque anidado)

resource "aws_s3vectors_index" "lujo_index" {
  vector_bucket_name = aws_s3vectors_vector_bucket.lujo_vector_store.vector_bucket_name
  index_name         = "business-knowledge-index"
  
  # Estos valores deben ser en minúsculas estrictas
  data_type       = "float32"
  dimension       = 1024
  distance_metric = "cosine"
}

# Crear el Rol de IAM para Bedrock
resource "aws_iam_role" "bedrock_kb_role" {
  name = "${var.client_name}-kb-role-${random_id.suffix.hex}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "bedrock.amazonaws.com"
      }
    }]
  })
}

# Darle permisos al rol para leer S3 y usar el Motor de Vectores
resource "aws_iam_role_policy" "bedrock_kb_policy" {
  name = "${var.client_name}-kb-policy"
  role = aws_iam_role.bedrock_kb_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Permisos para los documentos originales (PDFs)
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Effect   = "Allow"
        Resource = [
          aws_s3_bucket.raw_data_bucket.arn,
          "${aws_s3_bucket.raw_data_bucket.arn}/*"
        ]
      },
      {
        # NUEVO: Permisos para el Bucket de Vectores (S3 Vectors)
        Action   = [
          "s3vectors:*"
        ]
        Effect   = "Allow"
        Resource = [
          aws_s3vectors_vector_bucket.lujo_vector_store.vector_bucket_arn,
          "${aws_s3vectors_vector_bucket.lujo_vector_store.vector_bucket_arn}/*"
        ]
      },
      {
        Action   = ["bedrock:InvokeModel"]
        Effect   = "Allow"
        Resource = [
          "arn:aws:bedrock:us-east-1::foundation-model/amazon.titan-embed-text-v2:0"
        ]
      }
    ]
  })
}

resource "aws_bedrockagent_knowledge_base" "lujo_kb" {
  name     = "${var.client_name}-kb"
  role_arn = aws_iam_role.bedrock_kb_role.arn

  knowledge_base_configuration {
    type = "VECTOR"
    vector_knowledge_base_configuration {
      embedding_model_arn = "arn:aws:bedrock:us-east-1::foundation-model/amazon.titan-embed-text-v2:0"
    }
  }

  storage_configuration {
    type = "S3_VECTORS" # El nuevo tipo para la integración nativa
    s3_vectors_configuration {
      vector_bucket_arn = aws_s3vectors_vector_bucket.lujo_vector_store.vector_bucket_arn
      index_name        = aws_s3vectors_index.lujo_index.index_name
    }
  }
}

resource "aws_bedrockagent_data_source" "lujo_ds" {
  knowledge_base_id = aws_bedrockagent_knowledge_base.lujo_kb.id
  name              = "s3-docs-source"
  
  data_source_configuration {
    type = "S3"
    s3_configuration {
      bucket_arn = aws_s3_bucket.raw_data_bucket.arn
    }
  }
}

# ---------------------------------------------------------
# LAMBDA Y PERMISOS ACTUALIZADOS
# ---------------------------------------------------------

# 9. La Función Lambda (Ahora con KB_ID)
resource "aws_lambda_function" "whatsapp_bot" {
  function_name = "${var.client_name}-handler"
  role          = aws_iam_role.lambda_role.arn
  package_type  = "Image"
  image_uri = "${aws_ecr_repository.repo.repository_url}:latest"
  timeout       = 30 
  memory_size   = 512
  architectures = ["x86_64"]
  

  environment {
    variables = {
      DEPLOY_TIMESTAMP  = timestamp()
      TABLE_NAME        = aws_dynamodb_table.history.name
      KNOWLEDGE_BASE_ID = aws_bedrockagent_knowledge_base.lujo_kb.id
      WHATSAPP_TOKEN    = var.whatsapp_token
      PHONE_NUMBER_ID   = var.phone_number_id
      VERIFY_TOKEN      = var.verify_token
      API_VERSION       = var.api_version
    }
  }
  depends_on = [null_resource.docker_push]
}

# 10. Permisos IAM (Unificados: Dynamo + Bedrock + Logs)
resource "aws_iam_role" "lambda_role" {
  name = "${var.client_name}-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_policy" "lambda_policy" {
  name = "${var.client_name}-policy-unified"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = ["bedrock:InvokeModel", "bedrock:RetrieveAndGenerate", "bedrock:Retrieve"],
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

# 11. Webhook y Sincronización
resource "aws_lambda_function_url" "url" {
  function_name      = aws_lambda_function.whatsapp_bot.function_name
  authorization_type = "NONE"
}

resource "null_resource" "kb_sync" {
  depends_on = [aws_bedrockagent_data_source.lujo_ds, aws_s3_object.business_pdf]
  provisioner "local-exec" {
    command = "aws bedrock-agent start-ingestion-job --knowledge-base-id ${aws_bedrockagent_knowledge_base.lujo_kb.id} --data-source-id ${aws_bedrockagent_data_source.lujo_ds.data_source_id} --region ${var.aws_region}"
  }
}