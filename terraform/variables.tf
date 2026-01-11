variable "client_name" {
  description = "Nombre del cliente para prefijar los recursos"
  type        = string
  default     = "agencia-lujo"
}

variable "aws_region" {
  description = "Región de AWS"
  type        = string
  default     = "us-east-1"
}

variable "verify_token" {
  description = "Token secreto para validar el webhook en Meta"
  type        = string
  # No pongas default aquí, deja que lo lea de tfvars
}

variable "whatsapp_token" {
  description = "Token de acceso permanente de Meta"
  type        = string
  sensitive   = true 
}

variable "phone_number_id" {
  description = "Identificador del número de teléfono en Meta"
  type        = string
}
variable "api_version" {
  description = "Versión de la API de Graph de Meta (ej. v21.0)"
  type        = string
  default     = "v24.0"
}

variable "recipient_phone_number" {
  description = "Tu número personal para pruebas (formato 52...)"
  type        = string
}