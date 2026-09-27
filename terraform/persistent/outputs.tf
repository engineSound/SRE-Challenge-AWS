output "ci_role_arn" {
  description = "Store as the GitHub Actions variable AWS_CI_ROLE_ARN"
  value       = aws_iam_role.ci.arn
}

output "grafana_admin_secrets" {
  description = "Secrets Manager names for each environment's Grafana admin login"
  value       = { for env, s in aws_secretsmanager_secret.grafana_admin : env => s.name }
}

output "alertmanager_smtp_secret" {
  description = "Secrets Manager name for the Gmail SMTP login (value set manually)"
  value       = aws_secretsmanager_secret.alertmanager_smtp.name
}
