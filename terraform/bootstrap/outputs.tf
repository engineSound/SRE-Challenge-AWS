output "state_bucket" {
  description = "S3 bucket holding remote state for all other Terraform layers"
  value       = aws_s3_bucket.tfstate.bucket
}

output "backend_snippet" {
  description = "Backend block to paste into other layers (change key per layer)"
  value       = <<-EOT
    backend "s3" {
      bucket       = "${aws_s3_bucket.tfstate.bucket}"
      key          = "<layer>/terraform.tfstate"
      region       = "${var.region}"
      encrypt      = true
      use_lockfile = true
    }
  EOT
}
