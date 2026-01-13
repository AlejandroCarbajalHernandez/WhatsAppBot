output "whatsapp_callback_url" {
  description = "URL que debes pegar en el campo 'Callback URL' de Meta"
  # Referenciamos el nuevo nombre del recurso definido en el main.tf
  value       = aws_lambda_function_url.webhook_url.function_url
}

output "verify_token_to_use" {
  description = "Token que debes pegar en el campo 'Verify Token' de Meta"
  value       = var.verify_token
}

output "webhook_ecr_url" {
  description = "URL del repositorio ECR para el Webhook"
  value       = aws_ecr_repository.webhook_repo.repository_url
}