output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_version" {
  value = aws_eks_cluster.this.version
}

output "vpc_id" {
  value = aws_vpc.this.id
}

output "nat_public_ip" {
  description = "All outbound traffic from nodes appears to come from this address"
  value       = aws_eip.nat.public_ip
}

output "kubeconfig_command" {
  description = "Run this to point kubectl at the cluster"
  value       = "aws eks update-kubeconfig --name ${aws_eks_cluster.this.name} --region ${data.aws_region.current.region}"
}
