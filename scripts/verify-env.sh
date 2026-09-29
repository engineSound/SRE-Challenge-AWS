#!/usr/bin/env bash
# Verify that an environment built by terraform/envs/<env> actually behaves as designed.
# Checks health, network paths, least-privilege access (including what must be denied),
# storage, cost hygiene, and Terraform drift. Prints PASS/FAIL per check; exits 1 on any failure.
#
# Usage: scripts/verify-env.sh prod|preprod
set -uo pipefail

ENV="${1:?usage: $0 prod|preprod}"
case "$ENV" in prod) OTHER=preprod ;; preprod) OTHER=prod ;; *) echo "unknown env: $ENV"; exit 2 ;; esac

REGION=us-east-1
PROJECT=sre-challenge
CLUSTER="$PROJECT-$ENV"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
K="kubectl --context $CLUSTER"
PASSED=0; FAILED=0

pass() { printf "  \033[32mPASS\033[0m %-3s %s\n" "$1" "$2"; PASSED=$((PASSED+1)); }
fail() { printf "  \033[31mFAIL\033[0m %-3s %s\n" "$1" "$2"; FAILED=$((FAILED+1)); }
check() { local n="$1" desc="$2" ok="$3" detail="${4:-}"; if [ "$ok" = true ]; then pass "$n" "$desc${detail:+ ($detail)}"; else fail "$n" "$desc${detail:+ ($detail)}"; fi; }
section() { printf "\n\033[1m%s\033[0m\n" "$1"; }

echo "Verifying $CLUSTER in $REGION"
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" --alias "$CLUSTER" >/dev/null || { echo "cannot reach cluster $CLUSTER"; exit 1; }

VPC_ID=$(aws eks describe-cluster --name "$CLUSTER" --query cluster.resourcesVpcConfig.vpcId --output text)
VPC_PREFIX=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --query 'Vpcs[0].CidrBlock' --output text | cut -d. -f1-2).

# ---------------------------------------------------------------------------
section "Cluster health"

READY=$($K get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')
check 1 "Both nodes joined and Ready" "$([ "$READY" -ge 2 ] && echo true || echo false)" "$READY Ready"

BAD_ADDONS=""
for a in vpc-cni kube-proxy coredns eks-pod-identity-agent aws-ebs-csi-driver; do
  s=$(aws eks describe-addon --cluster-name "$CLUSTER" --addon-name "$a" --query addon.status --output text 2>/dev/null)
  [ "$s" = "ACTIVE" ] || BAD_ADDONS="$BAD_ADDONS $a=$s"
done
check 2 "All 5 add-ons ACTIVE" "$([ -z "$BAD_ADDONS" ] && echo true || echo false)" "${BAD_ADDONS# }"

NOT_RUNNING=$($K get pods -n kube-system --no-headers 2>/dev/null | awk '$3!="Running"' | wc -l | tr -d ' ')
TOTAL_SYS=$($K get pods -n kube-system --no-headers 2>/dev/null | wc -l | tr -d ' ')
check 3 "System pods Running" "$([ "$NOT_RUNNING" -eq 0 ] && [ "$TOTAL_SYS" -gt 0 ] && echo true || echo false)" "$TOTAL_SYS pods, $NOT_RUNNING not running"

SVC_IP=$($K get svc kubernetes -n default -o jsonpath='{.spec.clusterIP}')
DNS_OUT=$($K run "verify-dns-$RANDOM" --rm -i --restart=Never --quiet --image=busybox:1.36 --command -- nslookup kubernetes.default.svc.cluster.local 2>&1)
check 4 "In-cluster DNS resolves" "$(echo "$DNS_OUT" | grep -q "$SVC_IP" && echo true || echo false)" "kubernetes.default -> $SVC_IP"

# ---------------------------------------------------------------------------
section "Network"

ZONES=$($K get nodes -L topology.kubernetes.io/zone --no-headers | awk '{print $NF}' | sort -u | tr '\n' ' ')
check 5 "Nodes spread across 2 zones" "$([ "$(echo $ZONES | wc -w | tr -d ' ')" -eq 2 ] && echo true || echo false)" "$ZONES"

EXT_IPS=$($K get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="ExternalIP")].address}{end}')
NODE_IPS=$($K get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{" "}{end}')
OUTSIDE=$(for ip in $NODE_IPS; do echo "$ip"; done | grep -v "^$VPC_PREFIX")
check 6 "Nodes private (no public IP, inside VPC)" "$([ -z "$EXT_IPS" ] && [ -z "$OUTSIDE" ] && echo true || echo false)" "$NODE_IPS"

POD_OUT=$($K get pods -A -o jsonpath='{range .items[*]}{.status.podIP}{"\n"}{end}' | grep -v '^$' | grep -v "^$VPC_PREFIX" | wc -l | tr -d ' ')
check 7 "Pod IPs come from the VPC" "$([ "$POD_OUT" -eq 0 ] && echo true || echo false)" "prefix ${VPC_PREFIX}x.x"

NAT_IP=$(aws ec2 describe-nat-gateways --filter Name=vpc-id,Values="$VPC_ID" Name=state,Values=available --query 'NatGateways[0].NatGatewayAddresses[0].PublicIp' --output text)
# kubectl run --rm -i can echo the output twice; keep the first IP address only.
EGRESS_IP=$($K run "verify-egress-$RANDOM" --rm -i --restart=Never --quiet --image=curlimages/curl:8.10.1 -- -s --max-time 15 https://checkip.amazonaws.com 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+){3}' | head -1)
check 8 "Outbound traffic leaves through the NAT" "$([ -n "$EGRESS_IP" ] && [ "$EGRESS_IP" = "$NAT_IP" ] && echo true || echo false)" "pod sees $EGRESS_IP, NAT is $NAT_IP"

# ---------------------------------------------------------------------------
section "Security and access"

CANI=$($K auth can-i '*' '*' 2>/dev/null)
check 9 "You are cluster admin" "$([ "$CANI" = "yes" ] && echo true || echo false)"

# Expected: the 3 we define (admin user, CI role, node role) plus EKS's own
# service-linked role, which AWS adds automatically. Anything else is unexpected.
ENTRIES=$(aws eks list-access-entries --cluster-name "$CLUSTER" --query 'accessEntries' --output text | tr '\t' '\n' | sed 's#.*/##')
UNEXPECTED=$(echo "$ENTRIES" | grep -vxE "Design_one|$PROJECT-github-ci|$CLUSTER-node|AWSServiceRoleForAmazonEKS" | tr '\n' ' ')
MISSING=""; for want in Design_one "$PROJECT-github-ci" "$CLUSTER-node"; do echo "$ENTRIES" | grep -qx "$want" || MISSING="$MISSING $want"; done
check 10 "Only expected access entries (you, CI, nodes, EKS service role)" "$([ -z "${UNEXPECTED// /}" ] && [ -z "$MISSING" ] && echo true || echo false)" "$(echo $ENTRIES)${UNEXPECTED:+; unexpected: $UNEXPECTED}${MISSING:+; missing:$MISSING}"

CI_ARN=$(aws iam get-role --role-name "$PROJECT-github-ci" --query Role.Arn --output text)
CI_POLICIES=$(aws eks list-associated-access-policies --cluster-name "$CLUSTER" --principal-arn "$CI_ARN" --query 'associatedAccessPolicies[].policyArn' --output text | sed 's#.*/##')
check 11 "CI has read-only access only" "$([ "$CI_POLICIES" = "AmazonEKSViewPolicy" ] && echo true || echo false)" "$CI_POLICIES"

ENDPOINT=$(aws eks describe-cluster --name "$CLUSTER" --query cluster.endpoint --output text)
ANON=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "$ENDPOINT/api")
check 12 "API refuses callers with no login" "$([ "$ANON" = "401" ] || [ "$ANON" = "403" ] && echo true || echo false)" "HTTP $ANON"

ESO_ROLE=$(aws iam get-role --role-name "$CLUSTER-external-secrets" --query Role.Arn --output text)
sim() { aws iam simulate-principal-policy --policy-source-arn "$ESO_ROLE" --action-names secretsmanager:GetSecretValue \
          --resource-arns "$(aws secretsmanager describe-secret --secret-id "$1" --query ARN --output text)" \
          --query 'EvaluationResults[0].EvalDecision' --output text; }
OWN=$(sim "$PROJECT/$ENV/grafana-admin"); SHARED=$(sim "$PROJECT/shared/alertmanager-smtp")
check 13 "External Secrets CAN read $ENV + shared secrets" "$([ "$OWN" = "allowed" ] && [ "$SHARED" = "allowed" ] && echo true || echo false)" "$ENV=$OWN shared=$SHARED"
CROSS=$(sim "$PROJECT/$OTHER/grafana-admin")
check 14 "External Secrets CANNOT read $OTHER secrets" "$([ "$CROSS" != "allowed" ] && echo true || echo false)" "$OTHER=$CROSS"

ASSOC=$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER" --query 'associations[].serviceAccount' --output text | tr '\t' ' ')
check 15 "Pod identity links exist" "$(echo "$ASSOC" | grep -q external-secrets && echo "$ASSOC" | grep -q ebs-csi-controller-sa && echo true || echo false)" "$ASSOC"

# ---------------------------------------------------------------------------
section "Storage"

T="verify-$RANDOM"
cat <<EOF | $K apply -f - >/dev/null
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: { name: $T }
provisioner: ebs.csi.aws.com
parameters: { type: gp3 }
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: $T, namespace: default }
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: $T
  resources: { requests: { storage: 1Gi } }
---
apiVersion: v1
kind: Pod
metadata: { name: $T, namespace: default }
spec:
  restartPolicy: Never
  containers:
    - name: writer
      image: busybox:1.36
      command: ["sh", "-c", "echo proof > /data/proof.txt && cat /data/proof.txt"]
      volumeMounts: [{ name: data, mountPath: /data }]
  volumes: [{ name: data, persistentVolumeClaim: { claimName: $T } }]
EOF
$K wait pod/"$T" -n default --for=jsonpath='{.status.phase}'=Succeeded --timeout=180s >/dev/null 2>&1
PVC_PHASE=$($K get pvc "$T" -n default -o jsonpath='{.status.phase}' 2>/dev/null)
WROTE=$($K logs "$T" -n default 2>/dev/null)
check 16 "EBS disk created, attached and written" "$([ "$PVC_PHASE" = "Bound" ] && [ "$WROTE" = "proof" ] && echo true || echo false)" "claim $PVC_PHASE, file says '$WROTE'"
$K delete pod "$T" -n default --wait=true >/dev/null 2>&1; $K delete pvc "$T" -n default --wait=true >/dev/null 2>&1; $K delete storageclass "$T" >/dev/null 2>&1

# ---------------------------------------------------------------------------
section "Cost and hygiene"

SUPPORT=$(aws eks describe-cluster --name "$CLUSTER" --query cluster.upgradePolicy.supportType --output text)
check 17 "No paid extended support" "$([ "$SUPPORT" = "STANDARD" ] && echo true || echo false)" "$SUPPORT"

TAGGED=$(aws resourcegroupstaggingapi get-resources --tag-filters Key=Environment,Values="$ENV" Key=Project,Values="$PROJECT" --query 'length(ResourceTagMappingList)' --output text)
check 18 "Resources tagged Environment=$ENV" "$([ "$TAGGED" -ge 10 ] && echo true || echo false)" "$TAGGED tagged resources found"

# ---------------------------------------------------------------------------
section "Terraform matches reality"

( cd "$ROOT/terraform/envs/$ENV" && terraform plan -input=false -no-color -detailed-exitcode >/dev/null 2>&1 ); RC=$?
check 19 "No drift (terraform plan: no changes)" "$([ "$RC" -eq 0 ] && echo true || echo false)" "exit code $RC"

# ---------------------------------------------------------------------------
printf "\n\033[1mResult: %d passed, %d failed\033[0m\n" "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
