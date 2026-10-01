#!/usr/bin/env bash
# Verify the platform ArgoCD installed on an environment actually behaves as designed:
# GitOps state, storage, metrics, secrets from the vault (incl. what must be DENIED),
# Prometheus scraping and SLO rules, Alertmanager email config, Grafana login,
# the public app, and that admin tools are NOT public. Sends one test alert email.
#
# Usage: scripts/verify-platform.sh prod|preprod
set -uo pipefail

ENV="${1:?usage: $0 prod|preprod}"
case "$ENV" in prod) OTHER=preprod; APP_NS=sre-challenge ;; preprod) OTHER=prod; APP_NS=sre-challenge-preprod ;; *) echo "unknown env: $ENV"; exit 2 ;; esac

PROJECT=sre-challenge
CLUSTER="$PROJECT-$ENV"
REGION=us-east-1
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
K="kubectl --context $CLUSTER"
PROM="/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy"
AM="/api/v1/namespaces/monitoring/services/kube-prometheus-stack-alertmanager:9093/proxy"
PASSED=0; FAILED=0; PF_PID=""; TMP_ES=""

pass() { printf "  \033[32mPASS\033[0m %-3s %s\n" "$1" "$2"; PASSED=$((PASSED+1)); }
fail() { printf "  \033[31mFAIL\033[0m %-3s %s\n" "$1" "$2"; FAILED=$((FAILED+1)); }
check() { if [ "$3" = true ]; then pass "$1" "$2${4:+ ($4)}"; else fail "$1" "$2${4:+ ($4)}"; fi; }
tf() { if eval "$1"; then echo true; else echo false; fi; }
section() { printf "\n\033[1m%s\033[0m\n" "$1"; }
cleanup() {
  [ -n "$PF_PID" ] && kill "$PF_PID" >/dev/null 2>&1
  [ -n "$TMP_ES" ] && $K delete externalsecret "$TMP_ES" -n default --ignore-not-found >/dev/null 2>&1
}
trap cleanup EXIT
promq() { # instant query through the API server's service proxy (no port-forward needed)
  local q; q=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1")
  $K get --raw "$PROM/api/v1/query?query=$q" 2>/dev/null
}

echo "Verifying the platform on $CLUSTER"
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" --alias "$CLUSTER" >/dev/null || { echo "cannot reach $CLUSTER"; exit 1; }

# ---------------------------------------------------------------------------
section "GitOps (ArgoCD)"

APPS=$($K get applications -n argocd -o json)
N_APPS=$(echo "$APPS" | jq '.items | length')
N_OK=$(echo "$APPS" | jq '[.items[] | select(.status.sync.status=="Synced" and .status.health.status=="Healthy")] | length')
check 1 "All ArgoCD applications Synced + Healthy" "$(tf "[ $N_APPS -ge 8 ] && [ $N_OK -eq $N_APPS ]")" "$N_OK / $N_APPS"

GIT_HEAD=$(git -C "$ROOT" ls-remote origin -h refs/heads/main | cut -c1-40)
OFF=$(echo "$APPS" | jq -r --arg h "$GIT_HEAD" '[.items[] | select(.spec.source.repoURL|test("github.com")) | select(.status.sync.revision != $h) | .metadata.name] | join(" ")')
check 2 "Git-sourced apps are on GitHub main's latest commit" "$(tf "[ -z \"$OFF\" ]")" "main=${GIT_HEAD:0:7}${OFF:+; behind: $OFF}"

# ---------------------------------------------------------------------------
section "Platform"

DEF=$($K get storageclass -o json | jq -r '[.items[] | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"]=="true") | .metadata.name] | join(" ")')
check 3 "Exactly one default StorageClass, gp3" "$(tf "[ \"$DEF\" = gp3 ]")" "default: ${DEF:-none}"

HPA_CPU=$($K get hpa -n "$APP_NS" -o jsonpath='{.items[0].status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null)
check 4 "Autoscaler sees live CPU (metrics-server)" "$(tf "[ -n \"$HPA_CPU\" ]")" "current CPU ${HPA_CPU:-unknown}% of request"

STORE=$($K get clustersecretstore aws-secrets-manager -o jsonpath='{.status.conditions[0].status}' 2>/dev/null)
check 5 "Vault connection (ClusterSecretStore) ready" "$(tf "[ \"$STORE\" = True ]")"

ES_OK=$($K get externalsecrets -n monitoring -o json | jq '[.items[] | select(.status.conditions[]? | .type=="Ready" and .status=="True")] | length')
KEYS_G=$($K get secret grafana-admin -n monitoring -o json 2>/dev/null | jq -r '.data | keys | join(",")')
KEYS_A=$($K get secret alertmanager-config -n monitoring -o json 2>/dev/null | jq -r '.data | keys | join(",")')
check 6 "Vault secrets synced into the cluster (key names only)" "$(tf "[ $ES_OK -eq 2 ] && [ \"$KEYS_G\" = admin-password,admin-user ] && [ \"$KEYS_A\" = alertmanager.yaml ]")" "grafana-admin: $KEYS_G; alertmanager-config: $KEYS_A"

# NEGATIVE: this cluster's External Secrets must NOT be able to read the other environment's secret.
TMP_ES="verify-deny-$RANDOM"
cat <<EOF | $K apply -f - >/dev/null
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: { name: $TMP_ES, namespace: default }
spec:
  refreshInterval: 1h
  secretStoreRef: { kind: ClusterSecretStore, name: aws-secrets-manager }
  target: { name: $TMP_ES }
  dataFrom: [ { extract: { key: $PROJECT/$OTHER/grafana-admin } } ]
EOF
DENY_STATUS=""; DENY_MSG=""
for i in $(seq 1 12); do
  DENY_STATUS=$($K get externalsecret "$TMP_ES" -n default -o jsonpath='{.status.conditions[0].status}' 2>/dev/null)
  DENY_MSG=$($K get externalsecret "$TMP_ES" -n default -o jsonpath='{.status.conditions[0].message}' 2>/dev/null)
  [ -n "$DENY_STATUS" ] && break; sleep 5
done
LEAKED=$($K get secret "$TMP_ES" -n default --ignore-not-found -o name 2>/dev/null)
DENY_WHY=$(echo "$DENY_MSG" | grep -oE 'AccessDenied[A-Za-z]*|not authorized' | head -1)
check 7 "Vault DENIES this cluster the $OTHER secret (negative test)" "$(tf "[ \"$DENY_STATUS\" = False ] && [ -z \"$LEAKED\" ]")" "ready=${DENY_STATUS:-none}; ${DENY_WHY:-see: kubectl describe externalsecret}"
$K delete externalsecret "$TMP_ES" -n default --ignore-not-found >/dev/null 2>&1; TMP_ES=""

# ---------------------------------------------------------------------------
section "The app (public entry point)"

LB=$($K get svc sre-challenge-app -n "$APP_NS" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
if [ "$ENV" = prod ]; then
  WANT=$($K get deploy sre-challenge-app -n "$APP_NS" -o jsonpath='{.spec.template.spec.containers[0].image}'); WANT="${WANT##*:}"
  H=$(curl -s --max-time 10 "http://$LB/health" 2>/dev/null); V=$(curl -s --max-time 10 "http://$LB/version" 2>/dev/null)
  check 8 "Public URL answers /health and the deployed version" "$(tf "[ \"$H\" = OK ] && [ \"$V\" = \"$WANT\" ]")" "http://$LB  health=$H version=$V (deployed tag $WANT)"
  # Generate real user traffic so the SLI has data (20 page requests).
  for i in $(seq 1 20); do curl -s -o /dev/null --max-time 5 "http://$LB/" ; done
else
  check 8 "Preprod has no public address" "$(tf "[ -z \"$LB\" ]")" "${LB:-internal only}"
fi

PODS=$($K get pods -n "$APP_NS" -l app=sre-challenge -o json)
N_READY=$(echo "$PODS" | jq '[.items[] | select(.status.conditions[]? | .type=="Ready" and .status=="True")] | length')
NODES=$(echo "$PODS" | jq -r '[.items[].spec.nodeName] | unique | join(" ")')
ZONES=$(for n in $NODES; do $K get node "$n" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}{"\n"}'; done | sort -u | tr '\n' ' ')
MINR=$($K get hpa -n "$APP_NS" -o jsonpath='{.items[0].spec.minReplicas}')
check 9 "App pods Ready and spread across zones" "$(tf "[ $N_READY -ge $MINR ] && [ \$(echo $ZONES | wc -w) -ge 2 ]")" "$N_READY ready (min $MINR); zones: $ZONES"

PDB_OK=$($K get pdb sre-challenge-app -n "$APP_NS" -o jsonpath='{.status.disruptionsAllowed}' 2>/dev/null)
check 10 "Disruption budget allows safe node drains" "$(tf "[ \"${PDB_OK:-0}\" -ge 1 ]")" "disruptions allowed: ${PDB_OK:-0}"

# NEGATIVE: only the app may be public (no Grafana / Prometheus / ArgoCD load balancers).
PUBLIC=$($K get svc -A -o json | jq -r '[.items[] | select(.spec.type=="LoadBalancer") | "\(.metadata.namespace)/\(.metadata.name)"] | join(" ")')
if [ "$ENV" = prod ]; then EXPECT="$APP_NS/sre-challenge-app"; else EXPECT=""; fi
check 11 "Nothing public except the app (negative test)" "$(tf "[ \"$PUBLIC\" = \"$EXPECT\" ]")" "public services: ${PUBLIC:-none}"

# ---------------------------------------------------------------------------
section "Monitoring"

PVC=$($K get pvc -n monitoring -o json | jq -r '[.items[] | select(.metadata.name|test("prometheus")) | "\(.status.phase) \(.spec.storageClassName) \(.status.capacity.storage)"] | first')
check 12 "Prometheus stores data on a real disk" "$(tf "[ \"$PVC\" = 'Bound gp3 20Gi' ]")" "$PVC"

UP=$(promq 'up{job=~".*/sre-challenge-app"}' | jq -r '[.data.result[] | .value[1]] | "\(length) targets, \(map(select(.=="1"))|length) up"')
N_UP=$(echo "$UP" | awk '{print $3}'); N_T=$(echo "$UP" | awk '{print $1}')
check 13 "Prometheus scrapes every app pod" "$(tf "[ \"$N_T\" -ge $MINR ] && [ \"$N_T\" = \"$N_UP\" ]")" "$UP"

RULES=$($K get --raw "$PROM/api/v1/rules" 2>/dev/null | jq -r '[.data.groups[] | select(.name|test("sre-challenge")) | .rules[] | select(.type=="alerting") | .name] | join(",")')
check 14 "SLO burn-rate alerts loaded" "$(tf "echo \"$RULES\" | grep -q SREChallengeErrorBudgetFastBurn && echo \"$RULES\" | grep -q SREChallengeErrorBudgetSlowBurn")" "$RULES"

AVAIL=""
if [ "$ENV" = prod ]; then
  for i in $(seq 1 12); do
    AVAIL=$(promq 'sre_challenge:availability:ratio_rate5m' | jq -r '.data.result[0].value[1] // empty')
    [ -n "$AVAIL" ] && [ "$AVAIL" != "NaN" ] && break; sleep 10
  done
  check 15 "SLI is computed from real traffic" "$(tf "[ -n \"$AVAIL\" ] && [ \"$AVAIL\" != NaN ]")" "availability (5m) = ${AVAIL:-no data yet}"
fi

AMCFG=$($K get --raw "$AM/api/v2/status" 2>/dev/null | jq -r '.config.original // ""')
check 16 "Alertmanager runs our email config (from the vault)" "$(tf "echo \"\$AMCFG\" | grep -q 'smtp.gmail.com:587' && echo \"\$AMCFG\" | grep -q 'name: email'")" "smarthost smtp.gmail.com:587, receiver email"

# Grafana login with the vault password (via a short-lived port-forward; the password is never printed)
$K -n monitoring port-forward svc/kube-prometheus-stack-grafana 13000:80 >/dev/null 2>&1 & PF_PID=$!
sleep 4
GU=$($K get secret grafana-admin -n monitoring -o jsonpath='{.data.admin-user}' | base64 -d)
GP=$($K get secret grafana-admin -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d)
DASH=$(curl -s -u "$GU:$GP" "http://localhost:13000/api/search?query=SLI" | jq -r '.[0].title // empty')
check 17 "Grafana login with the vault password; SLI/SLO dashboard loaded" "$(tf "[ -n \"$DASH\" ]")" "${DASH:-dashboard not found}"
BAD=$(curl -s -o /dev/null -w '%{http_code}' -u "$GU:wrong-password" "http://localhost:13000/api/search")
check 18 "Grafana refuses a wrong password (negative test)" "$(tf "[ \"$BAD\" = 401 ]")" "HTTP $BAD"
unset GU GP
kill "$PF_PID" >/dev/null 2>&1; wait "$PF_PID" 2>/dev/null; PF_PID=""

# Send one test alert straight to Alertmanager; it should arrive by email within about a minute.
ENDS=$(python3 -c 'import datetime;print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(minutes=5)).strftime("%Y-%m-%dT%H:%M:%SZ"))')
ALERT=$(printf '[{"labels":{"alertname":"VerifyPlatformTestAlert","severity":"info","environment":"%s"},"annotations":{"summary":"Test alert from verify-platform.sh: the email path works"},"endsAt":"%s"}]' "$ENV" "$ENDS")
# Alertmanager's API needs a JSON content type, so post with curl through a short-lived port-forward.
$K -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 19093:9093 >/dev/null 2>&1 & PF_PID=$!
sleep 4
POST=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data "$ALERT" http://localhost:19093/api/v2/alerts)
kill "$PF_PID" >/dev/null 2>&1; wait "$PF_PID" 2>/dev/null; PF_PID=""
SEEN=$($K get --raw "$AM/api/v2/alerts" 2>/dev/null | jq '[.[] | select(.labels.alertname=="VerifyPlatformTestAlert")] | length')
check 19 "Alertmanager accepted a test alert" "$(tf "[ \"$POST\" = 200 ] && [ \"${SEEN:-0}\" -ge 1 ]")" "POST $POST; check the alert inbox for [FIRING:1] VerifyPlatformTestAlert within ~1 min"

# ---------------------------------------------------------------------------
section "Terraform matches reality"
( cd "$ROOT/terraform/envs/$ENV" && terraform plan -input=false -no-color -detailed-exitcode >/dev/null 2>&1 ); RC=$?
check 20 "No drift (terraform plan: no changes)" "$(tf "[ $RC -eq 0 ]")" "exit code $RC"

printf "\n\033[1mResult: %d passed, %d failed\033[0m\n" "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
