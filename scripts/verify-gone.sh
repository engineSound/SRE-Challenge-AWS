#!/usr/bin/env bash
# Safe teardown, part 3 of 3: prove an environment is gone, and that nothing
# shared (or the other environment) was touched.
# Usage: scripts/verify-gone.sh <prod|preprod>
set -uo pipefail

ENV=${1:-}
case "$ENV" in prod|preprod) ;; *) echo "usage: $0 <prod|preprod>"; exit 1 ;; esac
OTHER=$([ "$ENV" = prod ] && echo preprod || echo prod)
NAME="sre-challenge-$ENV"
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
pass=0; fail=0
check() { # check "<description>" <command...>  (passes when the command succeeds)
  local d=$1; shift
  if "$@" >/dev/null 2>&1; then echo "PASS  $d"; pass=$((pass+1)); else echo "FAIL  $d"; fail=$((fail+1)); fi
}
empty() { [ -z "$("$@" 2>/dev/null | tr -d '[:space:]')" ]; }

echo "== $ENV is gone =="
check "1  EKS cluster $NAME does not exist"        bash -c "! aws eks describe-cluster --name $NAME"
check "2  no VPC tagged Environment=$ENV"          empty aws ec2 describe-vpcs --filters Name=tag:Environment,Values=$ENV --query 'Vpcs[].VpcId' --output text
check "3  no live NAT gateway for $ENV"            empty aws ec2 describe-nat-gateways --filter Name=tag:Environment,Values=$ENV Name=state,Values=pending,available,deleting --query 'NatGateways[].NatGatewayId' --output text
check "4  no Elastic IP for $ENV"                  empty aws ec2 describe-addresses --filters Name=tag:Environment,Values=$ENV --query 'Addresses[].AllocationId' --output text
check "5  no unattached (orphan) EBS disks"        empty aws ec2 describe-volumes --filters Name=status,Values=available --query 'Volumes[].VolumeId' --output text
check "6  no load balancer outside $OTHER's VPC"   bash -c "o=\$(aws ec2 describe-vpcs --filters Name=tag:Environment,Values=$OTHER --query 'Vpcs[].VpcId' --output text); [ -z \"\$(aws elbv2 describe-load-balancers --query 'LoadBalancers[].VpcId' --output text | tr '\t' '\n' | grep -v \"^\$o\$\" | grep .)\" ]"
check "7  no IAM roles named $NAME-*"              empty aws iam list-roles --query "Roles[?starts_with(RoleName,'$NAME-')].RoleName" --output text
check "8  $ENV Terraform state is empty"           bash -c "cd '$ROOT_DIR/terraform/envs/$ENV' && [ -z \"\$(terraform state list)\" ]"

echo "== shared layers survived =="
for s in sre-challenge/shared/alertmanager-smtp sre-challenge/prod/grafana-admin sre-challenge/preprod/grafana-admin; do
  check "9  vault secret $s exists"                aws secretsmanager describe-secret --secret-id "$s"
done
check "10 GitHub CI role sre-challenge-github-ci exists" aws iam get-role --role-name sre-challenge-github-ci
check "11 GitHub OIDC provider exists"             bash -c "aws iam list-open-id-connect-providers --output text | grep -q token.actions.githubusercontent.com"
check "12 state bucket exists"                     aws s3api head-bucket --bucket sre-challenge-tfstate-4138fd

echo "== $OTHER untouched =="
skip=0
if aws eks describe-cluster --name "sre-challenge-$OTHER" >/dev/null 2>&1; then
  check "13 $OTHER cluster is ACTIVE"              bash -c "[ \"\$(aws eks describe-cluster --name sre-challenge-$OTHER --query cluster.status --output text)\" = ACTIVE ]"
  aws eks update-kubeconfig --name "sre-challenge-$OTHER" --region us-east-1 --alias "sre-challenge-$OTHER" >/dev/null 2>&1
  # Passes only if Argo CD answers with at least one app AND every app is Synced + Healthy.
  # (An error or an empty answer must FAIL, not pass.)
  check "14 $OTHER Argo CD apps all Synced+Healthy" bash -c "out=\$(kubectl --context sre-challenge-$OTHER -n argocd get applications --no-headers) && [ -n \"\$out\" ] && echo \"\$out\" | awk '\$2!=\"Synced\"||\$3!=\"Healthy\"{bad=1} END{exit bad}'"
else
  echo "SKIP  13 $OTHER cluster does not exist ($OTHER is down), nothing to compare"
  echo "SKIP  14 $OTHER Argo CD apps ($OTHER is down)"
  skip=2
fi

echo; echo "passed $pass, failed $fail$([ $skip -gt 0 ] && echo ", skipped $skip")"
[ "$fail" -eq 0 ]
