#!/usr/bin/env bash
# Build one environment from zero and prove it works. Bottom of the stack first:
#   1. Terraform: network, cluster, servers, access, Argo CD and its top app
#   2. Argo CD: installs the 7 apps from Git, wave by wave
#   3. Checks: verify-env + verify-platform
# Usage: scripts/env-up.sh <prod|preprod>
# Each step is timed and logged to ~/.sre-challenge/logs/.
set -euo pipefail

ENV=${1:-}
case "$ENV" in prod|preprod) ;; *) echo "usage: $0 <prod|preprod>"; exit 1 ;; esac
CTX="sre-challenge-$ENV"
REGION=us-east-1
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
TF_DIR="$ROOT_DIR/terraform/envs/$ENV"
LOG_DIR="$HOME/.sre-challenge/logs"; mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/env-up-$ENV-$(date '+%Y%m%d-%H%M%S').log"
exec > >(tee -a "$LOG") 2>&1
T0=$(date +%s)
say() { local e=$(( $(date +%s) - T0 )); printf '%s  +%02d:%02d  %s\n' "$(date '+%H:%M:%S')" $((e/60)) $((e%60)) "$*"; }

# --- 0. Before we start -------------------------------------------------------
say "env-up $ENV started (log: $LOG)"
aws sts get-caller-identity >/dev/null || { echo "AWS login not working. Log in first."; exit 1; }
# The shared layer must already be there: the vault secrets and the CI role.
for s in sre-challenge/shared/alertmanager-smtp "sre-challenge/$ENV/grafana-admin"; do
  aws secretsmanager describe-secret --secret-id "$s" >/dev/null || { echo "vault secret $s is missing; build terraform/persistent first"; exit 1; }
done
aws iam get-role --role-name sre-challenge-github-ci >/dev/null || { echo "CI role is missing; build terraform/persistent first"; exit 1; }
say "shared layer OK (vault secrets, CI role)"

# --- 1. Terraform: preview, confirm, build ------------------------------------
cd "$TF_DIR"
terraform init -input=false >/dev/null
say "previewing the build"
terraform plan -input=false -no-color -out=up.tfplan | grep -E '^Plan:|^No changes' || true
read -r -p "Type the environment name to build it: " answer
[ "$answer" = "$ENV" ] || { echo "not confirmed, nothing built"; exit 1; }
say "terraform apply started (about 15 minutes)"
if ! terraform apply -input=false -no-color up.tfplan > >(grep -E 'Apply complete|Error|error' || true); then
  echo "STOP: terraform apply failed (see the error above)."; exit 1
fi
rm -f up.tfplan
say "terraform apply finished"

# --- 2. Connect kubectl to the new cluster (same name as before) -------------
aws eks update-kubeconfig --name "$CTX" --region "$REGION" --alias "$CTX" >/dev/null
K="kubectl --context $CTX"
$K get nodes >/dev/null || { echo "cannot reach the new cluster"; exit 1; }
say "kubectl connected to $CTX"

# --- 3. Wait for Argo CD to install the 7 apps (top app + 7 = 8) --------------
say "waiting for Argo CD: 8 apps Synced + Healthy (up to 20 minutes)"
last=""
for _ in $(seq 240); do
  rows=$($K -n argocd get applications --no-headers 2>/dev/null | awk '{print $1" "$2"/"$3}' | sort || true)
  total=$(printf '%s\n' "$rows" | grep -c . || true)
  good=$(printf '%s\n' "$rows" | grep -c 'Synced/Healthy' || true)
  now="$good of $total ready"
  if [ "$now" != "$last" ]; then say "Argo CD: $now"; last="$now"; fi
  [ "$total" -ge 8 ] && [ "$good" -eq "$total" ] && break
  sleep 5
done
[ "$total" -ge 8 ] && [ "$good" -eq "$total" ] || { echo "Argo CD not ready after 20 minutes:"; $K -n argocd get applications; exit 1; }
say "Argo CD: all apps Synced + Healthy"

# --- 4. Prove it works --------------------------------------------------------
cd "$ROOT_DIR"
set +e
./scripts/verify-env.sh "$ENV"; e1=$?
./scripts/verify-platform.sh "$ENV"; e2=$?
set -e
if [ $e1 -eq 0 ] && [ $e2 -eq 0 ]; then say "DONE: $ENV is up and every check passed"; else say "BUILT, but some checks FAILED (see above)"; exit 1; fi
