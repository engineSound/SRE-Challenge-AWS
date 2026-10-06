# ArgoCD: the only in-cluster software Terraform installs. Everything else
# (platform tools, monitoring, the app) is installed by ArgoCD from Git.

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version

  values = [yamlencode({
    dex           = { enabled = false } # no SSO; admin login via port-forward only
    notifications = { enabled = false }
    configs = {
      cm = {
        # Report child Applications' health to the root app, so sync waves
        # wait for each layer to be Healthy before starting the next.
        "resource.customizations.health.argoproj.io_Application" = <<-LUA
          hs = {}
          hs.status = "Progressing"
          hs.message = ""
          if obj.status ~= nil and obj.status.health ~= nil then
            hs.status = obj.status.health.status
            if obj.status.health.message ~= nil then
              hs.message = obj.status.health.message
            end
          end
          return hs
        LUA
      }
    }
  })]

  # Needs running nodes, in-cluster DNS, and the admin access Helm logs in with.
  # The access link also fixes the destroy order: Terraform must uninstall Argo CD
  # BEFORE it deletes that access (found in the Oct 6 teardown practice).
  depends_on = [aws_eks_node_group.default, aws_eks_addon.coredns, aws_eks_access_policy_association.admin]
}

# The root "app of apps": points ArgoCD at k8s/argocd/<environment>/ in Git.
resource "helm_release" "argocd_root" {
  name       = "argocd-root"
  namespace  = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = var.argocd_apps_chart_version

  values = [yamlencode({
    applications = {
      "root-${var.environment}" = {
        namespace = "argocd"
        project   = "default"
        source = {
          repoURL        = var.git_repo_url
          targetRevision = var.git_revision
          path           = "k8s/argocd/${var.environment}"
        }
        destination = {
          server    = "https://kubernetes.default.svc"
          namespace = "argocd"
        }
        syncPolicy = {
          automated = { prune = true, selfHeal = true }
        }
      }
    }
  })]

  depends_on = [helm_release.argocd]
}
