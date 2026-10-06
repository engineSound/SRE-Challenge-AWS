#!/usr/bin/env bash
# Take one environment down and prove it's gone. Top of the stack first:
#   1. Kubernetes side: Argo CD apps and the disks/load balancers Kubernetes made (env-cleanup.sh)
#   2. Terraform side: preview, check it removes exactly what's in state, then destroy
#   3. Inspection: verify-gone.sh (gone, shared layer kept, other environment untouched)
#   4. Forget the old cluster in kubectl
# The shared layer (vault, CI role, state bucket) is never touched.
# Usage: scripts/env-down.sh <prod|preprod>
# Each step is timed and logged to ~/.sre-challenge/logs/.
set -euo pipefail

ENV=${1:-}
case "$ENV" in prod|preprod) ;; *) echo "usage: $0 <prod|preprod>"; exit 1 ;; esac
CTX="sre-challenge-$ENV"
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
TF_DIR="$ROOT_DIR/terraform/envs/$ENV"
LOG_DIR="$HOME/.sre-challenge/logs"; mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/env-down-$ENV-$(date '+%Y%m%d-%H%M%S').log"
exec > >(tee -a "$LOG") 2>&1
T0=$(date +%s)
say() { local e=$(( $(date +%s) - T0 )); printf '%s  +%02d:%02d  %s\n' "$(date '+%H:%M:%S')" $((e/60)) $((e%60)) "$*"; }

# --- 0. Confirm ---------------------------------------------------------------
say "env-down $ENV started (log: $LOG)"
aws sts get-caller-identity >/dev/null || { echo "AWS login not working. Log in first."; exit 1; }
echo "This takes $ENV down completely. Prod and the shared layer are not touched$( [ "$ENV" = prod ] && echo ' (except: you chose PROD)')."
read -r -p "Type the environment name to continue: " answer
[ "$answer" = "$ENV" ] || { echo "not confirmed, nothing changed"; exit 1; }
if [ "$ENV" = prod ]; then
  read -r -p "This is PROD, the public site. Type 'take prod down' to continue: " again
  [ "$again" = "take prod down" ] || { echo "not confirmed, nothing changed"; exit 1; }
fi

# --- 1. Kubernetes side (top of the stack) ------------------------------------
if aws eks describe-cluster --name "$CTX" >/dev/null 2>&1; then
  aws eks update-kubeconfig --name "$CTX" --region us-east-1 --alias "$CTX" >/dev/null
  say "step 1: Kubernetes side"
  ENV_CONFIRMED="$ENV" "$ROOT_DIR/scripts/env-cleanup.sh" "$ENV"
else
  say "step 1: cluster $CTX does not exist, so there is no Kubernetes side to clean"
fi

# --- 2. Terraform side --------------------------------------------------------
cd "$TF_DIR"
terraform init -input=false >/dev/null
# count managed resources only; data lookups (data.*) are read-only and never 'destroyed'
in_state=$(terraform state list | grep -vcE '(^|\.)data\.' || true)
if [ "$in_state" -eq 0 ]; then
  say "step 2: Terraform has nothing left to destroy"
else
  say "step 2: previewing the destroy"
  terraform plan -destroy -input=false -out=destroy.tfplan >/dev/null
  to_delete=$(terraform show -json destroy.tfplan | jq '[.resource_changes[] | select(.change.actions == ["delete"])] | length')
  other=$(terraform show -json destroy.tfplan | jq '[.resource_changes[] | select(.change.actions != ["delete"] and .change.actions != ["no-op"])] | length')
  say "plan: $to_delete to destroy, $other other changes; Terraform state has $in_state"
  if [ "$to_delete" -ne "$in_state" ] || [ "$other" -ne 0 ]; then
    echo "STOP: the plan does not match the state exactly. Nothing destroyed. Look at: terraform show destroy.tfplan"; exit 1
  fi
  read -r -p "Destroy these $to_delete resources? Type 'destroy' to continue: " go
  [ "$go" = "destroy" ] || { echo "not confirmed. Kubernetes side is already clean; Terraform side untouched."; exit 1; }
  say "terraform destroy started (about 8 minutes)"
  if ! terraform apply -input=false -no-color destroy.tfplan > >(grep -E 'Apply complete|Error|error' || true); then
    echo "STOP: terraform destroy failed (see the error above). The kubectl connection is kept so you can look."; exit 1
  fi
  rm -f destroy.tfplan
  say "terraform destroy finished"
fi

# --- 3. Inspection ------------------------------------------------------------
cd "$ROOT_DIR"
say "step 3: inspection"
set +e; ./scripts/verify-gone.sh "$ENV"; ok=$?; set -e

# --- 4. Forget the old cluster in kubectl -------------------------------------
cl=$(kubectl config view -o jsonpath="{.contexts[?(@.name=='$CTX')].context.cluster}" 2>/dev/null || true)
us=$(kubectl config view -o jsonpath="{.contexts[?(@.name=='$CTX')].context.user}" 2>/dev/null || true)
kubectl config delete-context "$CTX" >/dev/null 2>&1 || true
[ -n "$cl" ] && kubectl config delete-cluster "$cl" >/dev/null 2>&1 || true
[ -n "$us" ] && kubectl config unset "users.$us" >/dev/null 2>&1 || true
say "step 4: removed the old $CTX connection from kubectl"

if [ $ok -eq 0 ]; then say "DONE: $ENV is down and every check passed"; else say "DOWN, but some checks FAILED (see above)"; exit 1; fi
