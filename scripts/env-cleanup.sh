#!/usr/bin/env bash
# The Kubernetes side of env-down: the top of the stack, removed first.
#   1. delete the top app (root-<env>) so it stops putting things back
#   2. delete the 7 Argo CD apps, newest wave first (each removes what it installed)
#   3. delete Prometheus's disk claim, then wait until AWS has deleted the disk
#      (and, in prod, until the load balancer is gone)
# Why first: Terraform doesn't know about the disk or the load balancer. If the
# cluster went first, they would be left behind in AWS, still costing money.
# Usually called by scripts/env-down.sh. Usage: scripts/env-cleanup.sh <prod|preprod>
set -euo pipefail

ENV=${1:-}
case "$ENV" in prod|preprod) ;; *) echo "usage: $0 <prod|preprod>"; exit 1 ;; esac
CTX="sre-challenge-$ENV"
K="kubectl --context $CTX"
say() { echo "$(date '+%H:%M:%S') $*"; }

# --- 0. Safety: right cluster, and a typed confirmation -----------------------
cluster=$(kubectl config view -o jsonpath="{.contexts[?(@.name=='$CTX')].context.cluster}")
[[ "$cluster" == *"cluster/$CTX" ]] || { echo "context $CTX does not point at cluster $CTX"; exit 1; }
$K -n argocd get application "root-$ENV" >/dev/null
if [ "${ENV_CONFIRMED:-}" != "$ENV" ]; then   # env-down already asked
  echo "This removes every Argo CD application in $ENV (the apps and the platform) and the disks Kubernetes made."
  read -r -p "Type the environment name to continue: " answer
  [ "$answer" = "$ENV" ] || { echo "not confirmed, nothing changed"; exit 1; }
fi

# --- 1. Record the AWS resources Kubernetes made ------------------------------
LBS=$($K get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.status.loadBalancer.ingress[0].hostname}{"\n"}{end}')
VOLS=$($K get pv -o jsonpath='{range .items[*]}{.spec.csi.volumeHandle}{"\n"}{end}')
say "load balancers made by Kubernetes: ${LBS:-none}"
say "EBS disks made by Kubernetes: ${VOLS:-none}"

# --- 2. Delete the root app first ---------------------------------------------
# It has no finalizer, so its children stay. Without this step, the root app's
# selfHeal would re-create each child as soon as we delete it.
fin=$($K -n argocd get application "root-$ENV" -o jsonpath='{.metadata.finalizers}')
[ -z "$fin" ] || { echo "root-$ENV has finalizers ($fin); stopping so nothing cascades unexpectedly"; exit 1; }
say "deleting root-$ENV (children stay)"
$K -n argocd delete application "root-$ENV" --wait=true

# --- 3. Delete the children, newest wave first --------------------------------
# Each child carries Argo CD's resources finalizer: deleting it deletes what it
# installed, and kubectl waits until that's done.
for app in sre-challenge-app monitoring-config monitoring-stack monitoring-secrets secret-store external-secrets platform-storage; do
  say "deleting $app and everything it installed"
  if ! $K -n argocd delete application "$app" --ignore-not-found --timeout=10m; then
    echo "$app did not finish deleting. Look at: $K -n argocd get application $app -o yaml"; exit 1
  fi
  if [ "$app" = "monitoring-stack" ]; then
    # The disk claim belongs to Prometheus's StatefulSet, not to Argo CD, so it
    # survives the cascade. Delete it now that Prometheus is gone.
    say "deleting disk claims (Prometheus's disk)"
    $K delete pvc --all -A --timeout=5m
  fi
done

# --- 4. Wait until AWS has really removed them --------------------------------
for v in $VOLS; do
  say "waiting for disk $v to be deleted in AWS"
  for _ in $(seq 60); do aws ec2 describe-volumes --volume-ids "$v" >/dev/null 2>&1 || break; sleep 5; done
  aws ec2 describe-volumes --volume-ids "$v" >/dev/null 2>&1 && { echo "disk $v still exists after 5 min"; exit 1; }
  say "disk $v gone"
done
for h in $LBS; do
  say "waiting for load balancer $h to be deleted in AWS"
  for _ in $(seq 60); do
    [ -z "$(aws elbv2 describe-load-balancers --query "LoadBalancers[?DNSName=='$h'].LoadBalancerName" --output text)" ] && break; sleep 5
  done
  [ -z "$(aws elbv2 describe-load-balancers --query "LoadBalancers[?DNSName=='$h'].LoadBalancerName" --output text)" ] || { echo "load balancer $h still exists after 5 min"; exit 1; }
  say "load balancer gone"
done

say "Kubernetes side is clean: no Argo CD apps, no disks, no load balancers left"
