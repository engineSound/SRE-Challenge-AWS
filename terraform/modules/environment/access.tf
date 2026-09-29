# Who may do what in this environment.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_iam_role" "ci" {
  name = var.ci_role_name
}

# --- People and CI -> Kubernetes (EKS access entries) -----------------------

# Admin: your IAM user gets full cluster access.
resource "aws_eks_access_entry" "admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/${var.admin_user_name}"
}

resource "aws_eks_access_policy_association" "admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_eks_access_entry.admin.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

# CI: GitHub Actions gets read-only access, enough to check health; it cannot deploy.
resource "aws_eks_access_entry" "ci" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = data.aws_iam_role.ci.arn
}

resource "aws_eks_access_policy_association" "ci" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_eks_access_entry.ci.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"

  access_scope {
    type = "cluster"
  }
}

# --- Pods -> AWS (EKS Pod Identity) -----------------------------------------

# External Secrets Operator may read only this environment's secrets plus the
# shared ones (the Gmail SMTP login) from Secrets Manager.
resource "aws_iam_role" "external_secrets" {
  name               = "${local.name}-external-secrets"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

data "aws_iam_policy_document" "external_secrets" {
  statement {
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [
      "arn:aws:secretsmanager:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:secret:${var.project}/${var.environment}/*",
      "arn:aws:secretsmanager:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:secret:${var.project}/shared/*",
    ]
  }
}

resource "aws_iam_role_policy" "external_secrets" {
  name   = "read-${var.environment}-and-shared-secrets"
  role   = aws_iam_role.external_secrets.id
  policy = data.aws_iam_policy_document.external_secrets.json
}

# Binds the role to the service account External Secrets will run as.
# The service account doesn't need to exist yet; it's created when ESO is installed.
resource "aws_eks_pod_identity_association" "external_secrets" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "external-secrets"
  service_account = "external-secrets"
  role_arn        = aws_iam_role.external_secrets.arn
}
