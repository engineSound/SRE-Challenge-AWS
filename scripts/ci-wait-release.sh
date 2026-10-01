#!/usr/bin/env bash
# Run by CI after it commits a new image tag to Git. Uses READ-ONLY cluster access to wait
# until ArgoCD has rolled the new version out, and to read the in-cluster smoke test result.
# Fails the pipeline if the rollout or the smoke test doesn't succeed in time.
#
# Usage: scripts/ci-wait-release.sh prod|preprod <image-tag>
set -euo pipefail

ENV="${1:?usage: $0 prod|preprod <tag>}"
TAG="${2:?usage: $0 prod|preprod <tag>}"
case "$ENV" in prod) NS=sre-challenge ;; preprod) NS=sre-challenge-preprod ;; *) echo "unknown env: $ENV"; exit 2 ;; esac
DEPLOY=sre-challenge-app
JOB=sre-challenge-smoke-test
DEADLINE=$(( $(date +%s) + 900 ))   # 15 minutes: ArgoCD polls Git about every 3 minutes

say() { echo "[$(date -u +%H:%M:%S)] $*"; }
timeleft() { [ "$(date +%s)" -lt "$DEADLINE" ]; }

say "Waiting for ArgoCD to deploy $TAG to $ENV ($NS)"
while timeleft; do
  CUR=$(kubectl get deploy "$DEPLOY" -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].image}')
  [ "${CUR##*:}" = "$TAG" ] && break
  say "  still running ${CUR##*:}; waiting for ArgoCD to pick up the new commit"
  sleep 20
done
timeleft || { say "FAIL: ArgoCD did not deploy $TAG within 15 minutes"; exit 1; }
say "Deployment spec now uses $TAG"

say "Waiting for the rollout to finish"
kubectl rollout status deploy/"$DEPLOY" -n "$NS" --timeout=600s

say "Waiting for the in-cluster smoke test of $TAG"
while timeleft; do
  LOG=$(kubectl logs job/"$JOB" -n "$NS" 2>/dev/null || true)
  if echo "$LOG" | grep -qx "version=$TAG"; then
    SUCCEEDED=$(kubectl get job "$JOB" -n "$NS" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)
    FAILED=$(kubectl get job "$JOB" -n "$NS" -o jsonpath='{.status.failed}' 2>/dev/null || true)
    if [ "${SUCCEEDED:-0}" -ge 1 ]; then echo "$LOG" | sed 's/^/    /'; say "PASS: smoke test passed for $TAG"; break; fi
    if [ "${FAILED:-0}" -ge 3 ]; then echo "$LOG" | sed 's/^/    /'; say "FAIL: smoke test failed for $TAG"; exit 1; fi
  fi
  sleep 10
done
timeleft || { say "FAIL: no passing smoke test for $TAG within 15 minutes"; exit 1; }

if [ "$ENV" = prod ]; then
  LB=$(kubectl get svc "$DEPLOY" -n "$NS" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
  V=$(curl -fsS --max-time 10 --retry 5 --retry-delay 5 "http://$LB/version")
  [ "$V" = "$TAG" ] || { say "FAIL: public URL serves $V, expected $TAG"; exit 1; }
  say "PASS: public URL serves $TAG"
fi
say "Release $TAG verified on $ENV"
