# EKS: AWS runs the Kubernetes control plane; we run the worker nodes.

# --- Control plane ----------------------------------------------------------

data "aws_iam_policy_document" "cluster_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${local.name}-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_trust.json
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "this" {
  name     = local.name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = aws_subnet.private[*].id
    endpoint_private_access = true # nodes talk to the API inside the VPC
    endpoint_public_access  = true # laptop and GitHub runners; every call still needs IAM auth
  }

  # Who may use the cluster is managed with EKS access entries (access.tf),
  # not the old aws-auth ConfigMap. Nobody gets admin implicitly.
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false
  }

  # Core add-ons are installed explicitly as EKS-managed add-ons (addons.tf).
  bootstrap_self_managed_addons = false

  # Never slide into paid extended support when this version ages out.
  upgrade_policy {
    support_type = "STANDARD"
  }

  depends_on = [aws_iam_role_policy_attachment.cluster]
}

# --- Worker nodes -----------------------------------------------------------

data "aws_iam_policy_document" "node_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${local.name}-node"
  assume_role_policy = data.aws_iam_policy_document.node_trust.json
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",          # join the cluster
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",               # give pods VPC IP addresses
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly", # pull EKS add-on images
  ])
  role       = aws_iam_role.node.name
  policy_arn = each.value
}

resource "aws_eks_node_group" "default" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "default"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = aws_subnet.private[*].id # nodes are never directly reachable from the internet

  ami_type       = "AL2023_x86_64_STANDARD"
  capacity_type  = "ON_DEMAND"
  instance_types = [var.node_instance_type]

  scaling_config {
    desired_size = var.node_count
    min_size     = var.node_count
    max_size     = var.node_max_count
  }

  update_config {
    max_unavailable = 1 # replace nodes one at a time during upgrades
  }

  depends_on = [
    aws_iam_role_policy_attachment.node,
    aws_eks_addon.vpc_cni, # pod networking must exist before nodes can become Ready
    aws_eks_addon.kube_proxy,
    aws_eks_addon.pod_identity_agent,
    aws_route_table_association.private, # nodes need their route out through the NAT to join
  ]
}
