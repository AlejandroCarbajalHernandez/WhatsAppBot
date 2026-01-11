output "webhook_url" {
  description = "URL que debes pegar en el campo 'Callback URL' de Meta"
  value       = aws_lambda_function_url.url.function_url
}

output "verify_token_to_use" {
  description = "Token que debes pegar en el campo 'Verify Token' de Meta"
  value       = var.verify_token
}

output "ecr_repository_url" {
  description = "URL del repositorio de Docker para futuras actualizaciones"
  value       = aws_ecr_repository.repo.repository_url
}
