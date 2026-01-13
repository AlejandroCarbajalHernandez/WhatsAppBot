# 1. Configuración del Proveedor
provider "aws" {
  region = var.aws_region
}

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

data "aws_caller_identity" "current" {}

resource "random_id" "suffix" {
  byte_length = 4
}

# ---------------------------------------------------------
# 2. ROLES DE IAM UNIFICADOS (Resuelve errores de referencias)
# ---------------------------------------------------------

# Rol para Bedrock (Agente + Knowledge Base)
resource "aws_iam_role" "bedrock_unified_role" {
  name = "agencia-lujo-bedrock-unified-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "bedrock.amazonaws.com"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
          ArnLike = {
            "aws:SourceArn" = [
              "arn:aws:bedrock:us-east-1:${data.aws_caller_identity.current.account_id}:agent/*",
              "arn:aws:bedrock:us-east-1:${data.aws_caller_identity.current.account_id}:knowledge-base/*"
            ]
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "bedrock_unified_policy" {
  name = "agencia-lujo-bedrock-permissions"
  role = aws_iam_role.bedrock_unified_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:Retrieve"
        ]
        Resource = [
          "arn:aws:bedrock:us-east-1::foundation-model/*",
          "arn:aws:bedrock:us-east-1:${data.aws_caller_identity.current.account_id}:knowledge-base/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::*",
          "arn:aws:s3:::*/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "s3vectors:*"
        ]
        Resource = [
          "arn:aws:s3vectors:us-east-1:${data.aws_caller_identity.current.account_id}:bucket/*"
        ]
      }
    ]
  })
}

# Rol para Lambdas (Webhook + Acción)
resource "aws_iam_role" "lambda_unified_role" {
  name = "${var.client_name}-lambda-unified-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "lambda_permissions" {
  name = "${var.client_name}-lambda-policy"
  role = aws_iam_role.lambda_unified_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Action = ["bedrock:InvokeAgent", "dynamodb:*", "logs:*"], Effect = "Allow", Resource = "*" }
    ]
  })
}

# ---------------------------------------------------------
# 3. REPOSITORIOS ECR Y DOCKER
# ---------------------------------------------------------

resource "aws_ecr_repository" "webhook_repo" {
  name                 = "${var.client_name}-webhook"
  image_tag_mutability = "MUTABLE"
  force_delete         = true 
}

resource "aws_ecr_repository" "action_repo" {
  name                 = "${var.client_name}-action-executor"
  image_tag_mutability = "MUTABLE"
  force_delete         = true 
}

resource "null_resource" "docker_push" {
  triggers = {
    webhook_code = md5(file("../src/app.py"))
    action_code  = md5(file("../src/appointments.py"))
  }

  provisioner "local-exec" {
    command = <<EOF
      aws ecr get-login-password --region ${var.aws_region} | docker login --username AWS --password-stdin ${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com
      docker buildx build --platform linux/amd64 --provenance=false -t ${var.client_name}-webhook:latest -f ../Dockerfile --build-arg ENTRY_POINT=app.lambda_handler ../
      docker tag ${var.client_name}-webhook:latest ${aws_ecr_repository.webhook_repo.repository_url}:latest
      docker push ${aws_ecr_repository.webhook_repo.repository_url}:latest
      docker buildx build --platform linux/amd64 --provenance=false -t ${var.client_name}-action:latest -f ../Dockerfile --build-arg ENTRY_POINT=appointments.lambda_handler ../
      docker tag ${var.client_name}-action:latest ${aws_ecr_repository.action_repo.repository_url}:latest
      docker push ${aws_ecr_repository.action_repo.repository_url}:latest
    EOF
  }
}

# ---------------------------------------------------------
# 4. DYNAMODB (Sintaxis Corregida - Resuelve Error línea 88)
# ---------------------------------------------------------
# Tabla para guardar el historial de chat (Sesiones de WhatsApp)
resource "aws_dynamodb_table" "history" {
  name           = "${var.client_name}-chat-history"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "SessionId"
  range_key      = "Timestamp" # Esto soluciona el error de "Unused attributes"

  attribute {
    name = "SessionId"
    type = "S"
  }

  attribute {
    name = "Timestamp"
    type = "S"
  }

  # Mantenemos el TTL para la limpieza automática
  ttl {
    attribute_name = "TimeToExist"
    enabled        = true
  }

  tags = { 
    Client = var.client_name 
  }
}
resource "aws_dynamodb_table" "appointments" {
  name           = "${var.client_name}-medical-appointments"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "doctor_id"
  range_key      = "appointment_id"

  attribute {
    name = "doctor_id"
    type = "S"
  }

  attribute {
    name = "appointment_id"
    type = "S"
  }

  attribute {
    name = "appointment_date"
    type = "S"
  }

  global_secondary_index {
    name               = "DateIndex"
    hash_key           = "appointment_date"
    projection_type    = "ALL"
  }

  tags = { Client = var.client_name }
}

# ---------------------------------------------------------
# 5. BEDROCK KB Y AGENTE (Referencias Corregidas)
# ---------------------------------------------------------

resource "aws_s3_bucket" "raw_data_bucket" {
  bucket        = "${var.client_name}-raw-docs-${random_id.suffix.hex}"
  force_destroy = true
}

resource "aws_s3vectors_vector_bucket" "vector_store" {
  vector_bucket_name = "${var.client_name}-vectors-${random_id.suffix.hex}"
}

resource "aws_s3vectors_index" "kb_index" {
  vector_bucket_name = aws_s3vectors_vector_bucket.vector_store.vector_bucket_name
  index_name         = "${var.client_name}-index"
  data_type          = "float32"
  dimension          = 1024
  distance_metric    = "cosine"
}

resource "aws_bedrockagent_knowledge_base" "kb" {
  name     = "${var.client_name}-kb"
  role_arn = aws_iam_role.bedrock_unified_role.arn # Referencia Corregida

  knowledge_base_configuration {
    type = "VECTOR"
    vector_knowledge_base_configuration {
      embedding_model_arn = "arn:aws:bedrock:us-east-1::foundation-model/amazon.titan-embed-text-v2:0"
    }
  }

  storage_configuration {
    type = "S3_VECTORS"
    s3_vectors_configuration {
      vector_bucket_arn = aws_s3vectors_vector_bucket.vector_store.vector_bucket_arn
      index_name        = aws_s3vectors_index.kb_index.index_name
    }
  }
}

resource "aws_bedrockagent_agent" "doctor_assistant" {
  agent_name                  = "${var.client_name}-agent"
  agent_resource_role_arn     = aws_iam_role.bedrock_unified_role.arn # Referencia Corregida
  foundation_model            = "amazon.nova-lite-v1:0"
  instruction = <<EOT
Eres un asistente virtual médico proactivo y resolutivo para el cliente $${var.client_name}. Tu objetivo es resolver dudas de la clínica o agendar citas médicas, siguiendo EXACTAMENTE este orden paso a paso:

<pasos_de_conversacion>
PASO 1: SALUDO Y ENRUTAMIENTO
Si el usuario dice "Hola" o te saluda, dale la bienvenida y pregúntale DIRECTAMENTE qué necesita: "¡Hola! Bienvenido. ¿Te gustaría agendar una cita médica o tienes alguna duda sobre nuestros servicios (ubicación, indicaciones, etc.)?".
- Si el usuario te hace una pregunta, usa tu base de conocimientos (Knowledge Base) para responderle.
- Si el usuario quiere agendar, avanza al PASO 2.

PASO 2: SOLICITUD DE FECHA (Solo para agendar)
Pregúntale para qué día y mes le gustaría revisar la disponibilidad. (Asume siempre el año 2026. Si te da un día sin mes, pregúntale el mes).

PASO 3: MOSTRAR DISPONIBILIDAD (Requiere Herramienta)
Cuando tengas la fecha exacta, EJECUTA INMEDIATAMENTE la función 'getAvailability'. Muestra los resultados al usuario y pregúntale: "¿Cuál de estos horarios prefieres?".

PASO 4: PEDIR NOMBRE
Cuando el usuario elija un horario válido, NO agendes todavía. Pregúntale de forma natural: "Perfecto, ¿me podrías proporcionar tu nombre completo para registrar la cita?".

PASO 5: CONFIRMAR Y AGENDAR CITA (Requiere Herramienta)
Una vez que tengas la fecha, la hora y el nombre del usuario, EJECUTA INMEDIATAMENTE la función 'bookAppointment' (date, time, name). Al confirmar el éxito, despídete amablemente.
</pasos_de_conversacion>

<reglas_estrictas>
- TRABAJA EN SILENCIO: No narres tus acciones en ningún momento.
- PROHIBIDO CALCULAR FECHAS RELATIVAS: No tienes reloj. Si dicen "mañana" o "hoy", pídeles la fecha exacta.
- NUNCA ejecutes 'bookAppointment' sin tener el nombre del usuario.
- PROTECCIÓN RAG: NUNCA inventes respuestas a dudas médicas o de la clínica. Si la respuesta no está en tu base de conocimientos, dile al paciente que por favor se comunique a recepción.
</reglas_estrictas>
EOT
}

resource "aws_bedrockagent_agent_alias" "agent_alias" {
  agent_id         = aws_bedrockagent_agent.doctor_assistant.id
  agent_alias_name = "prod"
}

# Resuelve Error línea 198 (Missing required arguments)
resource "aws_bedrockagent_agent_knowledge_base_association" "kb_assoc" {
  agent_id             = aws_bedrockagent_agent.doctor_assistant.id
  knowledge_base_id    = aws_bedrockagent_knowledge_base.kb.id
  agent_version        = "DRAFT"
  description          = "Base de conocimientos médicos y protocolos del doctor."
  knowledge_base_state = "ENABLED" 
}

# ---------------------------------------------------------
# 6. LAMBDAS Y ACCIONES
# ---------------------------------------------------------

resource "aws_lambda_function" "whatsapp_webhook" {
  function_name = "${var.client_name}-webhook-handler"
  role          = aws_iam_role.lambda_unified_role.arn
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.webhook_repo.repository_url}:latest"
  image_config {
    command = ["app.lambda_handler"]
  }
  timeout       = 30

  environment {
    variables = {
      AGENT_ID        = aws_bedrockagent_agent.doctor_assistant.id
      
      # MAGIA PURA: Esto apunta todo el tráfico de WhatsApp al Borrador (DRAFT)
      AGENT_ALIAS_ID  = "TSTALIASID"
      
      WHATSAPP_TOKEN  = var.whatsapp_token
      PHONE_NUMBER_ID = var.phone_number_id
      TABLE_NAME      = aws_dynamodb_table.history.name
    }
  }
  depends_on = [null_resource.docker_push]
}

resource "aws_lambda_function" "appointment_action" {
  function_name = "${var.client_name}-action-executor"
  role          = aws_iam_role.lambda_unified_role.arn
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.action_repo.repository_url}:latest"
  image_config {
    command = ["appointments.lambda_handler"] 
  }
  timeout       = 30

  environment {
    variables = {
      APPOINTMENTS_TABLE = aws_dynamodb_table.appointments.name
    }
  }
  depends_on = [null_resource.docker_push]
}

resource "aws_bedrockagent_agent_action_group" "actions" {
  action_group_name          = "CitasMedicas"
  agent_id                   = aws_bedrockagent_agent.doctor_assistant.id
  agent_version              = "DRAFT"
  skip_resource_in_use_check = true

  action_group_executor {
    lambda = aws_lambda_function.appointment_action.arn 
  }

  function_schema {
    member_functions {
      functions {
        name        = "getAvailability"
        description = "Usa esta función INMEDIATAMENTE y de forma OBLIGATORIA cuando el usuario pregunte por horarios, qué días hay libres, o quiera saber la disponibilidad médica. NUNCA respondas sobre disponibilidad sin usar esta función primero."
        parameters {
          map_block_key = "date"
          type          = "string"
          description   = "La fecha exacta a consultar, SIEMPRE en formato YYYY-MM-DD (ej. 2026-01-28). Si el usuario no da el año, asume 2026."
          required      = true
        }
      }

      functions {
        name        = "bookAppointment"
        description = "Usa esta función INMEDIATAMENTE y de forma OBLIGATORIA cuando el usuario confirme que quiere agendar, reservar o apartar un horario específico. NUNCA pidas confirmación si ya te dieron fecha y hora."
        parameters {
          map_block_key = "date"
          type          = "string"
          description   = "La fecha de la cita en formato YYYY-MM-DD (ej. 2026-01-28)."
          required      = true
        }
        parameters {
          map_block_key = "time"
          type          = "string"
          description   = "La hora exacta de la cita en formato de 24 horas HH:MM (ej. 15:00)."
          required      = true
        }
        parameters {
          map_block_key = "name"
          type          = "string"
          description   = "El nombre completo del paciente que solicita la cita médica."
          required      = true
        }
      }
    }
  }
}

resource "aws_lambda_permission" "allow_agent" {
  statement_id  = "AllowBedrockInvocation"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.appointment_action.function_name
  principal     = "bedrock.amazonaws.com"
  source_account = data.aws_caller_identity.current.account_id
  # Esto asegura que el Agente ya exista por completo antes de intentar darle permiso
  depends_on = [aws_bedrockagent_agent.doctor_assistant]
}

resource "aws_lambda_function_url" "webhook_url" {
  function_name      = aws_lambda_function.whatsapp_webhook.function_name
  authorization_type = "NONE"
}


resource "aws_bedrockagent_agent_alias" "current" {
  agent_alias_name = "prod_v2"
  agent_id         = aws_bedrockagent_agent.doctor_assistant.id
}

resource "aws_bedrockagent_data_source" "faq_source" {
  name              = "PreguntasFrecuentes-S3"

  knowledge_base_id = aws_bedrockagent_knowledge_base.kb.id 

  data_source_configuration {
    type = "S3"
    s3_configuration {
      bucket_arn = aws_s3_bucket.raw_data_bucket.arn
    }
  }
}

# ---------------------------------------------------------
# 7. REPOSITORIO ECR Y CONFIGURACIÓN DE LA API PARA REACT
# ---------------------------------------------------------

# Nuevo repositorio exclusivo para el backend de Flask
resource "aws_ecr_repository" "api_repo" {
  name                 = "${var.client_name}-frontend-api"
  image_tag_mutability = "MUTABLE"
  force_delete         = true 
}

# Compilador de Docker independiente para la carpeta backend
resource "null_resource" "docker_push_api" {
  triggers = {
    api_code = md5(file("../backend/app.py"))
  }

  provisioner "local-exec" {
    command = <<EOF
      aws ecr get-login-password --region ${var.aws_region} | docker login --username AWS --password-stdin ${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com
      
      # Compilamos usando la carpeta backend como el contexto de trabajo
      docker buildx build --platform linux/amd64 --provenance=false -t ${var.client_name}-api:latest -f ../backend/Dockerfile --build-arg ENTRY_POINT=app.lambda_handler ../backend
      
      docker tag ${var.client_name}-api:latest ${aws_ecr_repository.api_repo.repository_url}:latest
      docker push ${aws_ecr_repository.api_repo.repository_url}:latest
    EOF
  }
}

# La nueva Lambda que ejecutará el servidor monolítico de Flask
resource "aws_lambda_function" "frontend_api" {
  function_name = "${var.client_name}-frontend-api"
  role          = aws_iam_role.lambda_unified_role.arn # Reutiliza tu rol unificado con acceso total a DynamoDB
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.api_repo.repository_url}:latest"
  timeout       = 30

  image_config {
    command = ["app.lambda_handler"]
  }
  environment {
    variables = {
      # Inyectamos el nombre de tu tabla de citas médicas de forma dinámica
      APPOINTMENTS_TABLE = aws_dynamodb_table.appointments.name
    }
  }
  depends_on = [null_resource.docker_push_api]
}

# URL pública para que la aplicación de React pueda hacer peticiones HTTP
resource "aws_lambda_function_url" "api_url" {
  function_name      = aws_lambda_function.frontend_api.function_name
  authorization_type = "NONE"
  # Dejamos el bloque cors vacío aquí porque Flask se encarga de eso con CORS(app)
}

# Bloque Output para imprimir la URL directamente en tu pantalla al terminar
output "URL_PARA_DENIA" {
  value       = aws_lambda_function_url.api_url.function_url
  description = "Copia esta URL de la terminal y pásasela a Denia para su código de React"
}

# Conexión automática entre el Agente y la Base de Conocimientos
resource "aws_bedrockagent_agent_knowledge_base_association" "agencia_lujo_agent_kb_assoc" {
  agent_id             = "I4TWJQRRHH"
  knowledge_base_id    = "KBDNU7EGUR"
  description          = "Base de conocimientos para dudas de los pacientes y estacionamiento"
  knowledge_base_state = "ENABLED"
  agent_version        = "DRAFT" # 🛡️ EL PARCHE: Fuerza la versión para evitar el bug de la API
}