# Petclinic Platform — Operations Runbook

## Prerequisites

```bash
# Configure kubectl for dev
aws eks update-kubeconfig --name petclinic-dev --region ap-south-1

# Configure kubectl for prod
aws eks update-kubeconfig --name petclinic-prod --region ap-south-1

# Verify cluster access
kubectl get nodes
kubectl get pods -n petclinic-dev
kubectl get pods -n petclinic-prod
```

---

## Complete Deploy Sequence (Fresh Cluster)

Run this after every destroy+recreate. Takes ~45 minutes total.

```bash
cd ~/petclinic-infra

# ── DEV ──────────────────────────────────────────────────────────────────────
./scripts/tf.sh dev apply

rm -f /tmp/tfstate-dev.json
./scripts/generate-config.sh dev
git add helm-values/dev/ k8s/ monitoring/ argocd/
git commit -m "config: update dynamic values for dev" && git push

./scripts/setup-cluster.sh dev
./scripts/build-push-images.sh --tag v1.0.0
./scripts/update-dns-and-ingress.sh dev
./scripts/smoke-test.sh petclinic-dev

# ── PROD ─────────────────────────────────────────────────────────────────────
./scripts/tf.sh prod apply

rm -f /tmp/tfstate-prod.json
./scripts/generate-config.sh prod
git add helm-values/prod/ k8s/ monitoring/ argocd/
git commit -m "config: update dynamic values for prod" && git push

aws eks update-kubeconfig --name petclinic-prod --region ap-south-1
./scripts/setup-cluster.sh prod
./scripts/build-push-images.sh --tag v1.0.0 --env prod
./scripts/update-dns-and-ingress.sh prod

# Prod has no auto-sync — manually trigger initial deployment
for APP in config-server-prod discovery-server-prod api-gateway-prod \
           customers-service-prod visits-service-prod vets-service-prod \
           genai-service-prod admin-server-prod; do
  kubectl patch application "${APP}" -n argocd \
    --type merge \
    -p '{"operation":{"sync":{"syncStrategy":{"apply":{"force":false}}}}}' \
    2>/dev/null && echo "Syncing: ${APP}"
done

echo "Waiting for prod pods to start (~3 min)..."
sleep 180

# Seed prod RDS with test data (ONCE on fresh database)
./scripts/seed-prod-data.sh

aws eks update-kubeconfig --name petclinic-dev --region ap-south-1
./scripts/smoke-test.sh petclinic-prod
```

---

## Destroy Everything

```bash
cd ~/petclinic-infra
./scripts/full-cleanup.sh
# Type 'destroy' when prompted
# Takes ~15-20 minutes
```

---

## Restart a Service

```bash
# Dev
kubectl rollout restart deployment/{service-name} -n petclinic-dev
kubectl rollout status deployment/{service-name} -n petclinic-dev

# Prod
aws eks update-kubeconfig --name petclinic-prod --region ap-south-1
kubectl rollout restart deployment/{service-name} -n petclinic-prod
kubectl rollout status deployment/{service-name} -n petclinic-prod
```

---

## Scale a Service

```bash
# Dev — manual scale (ArgoCD selfHeal will restore to 1 within 3 min)
# Disable selfHeal first if you want it to stay scaled
kubectl patch application {service-name}-dev -n argocd \
  --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":false}}}}'
kubectl scale deployment/{service-name} --replicas=0 -n petclinic-dev

# Re-enable selfHeal when done
kubectl patch application {service-name}-dev -n argocd \
  --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":true}}}}'

# Prod — scale manually (no auto-sync)
aws eks update-kubeconfig --name petclinic-prod --region ap-south-1
kubectl scale deployment/{service-name} --replicas=3 -n petclinic-prod
```

---

## Promote Image to Prod (Manual CI/CD)

```bash
cd ~/petclinic-infra

# Get current dev tag
NEW_TAG=$(grep "tag:" helm-values/dev/{service-name}.yaml | \
  awk '{print $2}' | tr -d '"')
echo "Promoting: ${NEW_TAG}"

# Login to ECR
aws ecr get-login-password --region ap-south-1 | \
  docker login --username AWS --password-stdin \
  {account}.dkr.ecr.ap-south-1.amazonaws.com

# Copy image from dev to prod ECR (no rebuild)
docker pull {account}.dkr.ecr.ap-south-1.amazonaws.com/petclinic-dev/{service-name}:${NEW_TAG}
docker tag \
  {account}.dkr.ecr.ap-south-1.amazonaws.com/petclinic-dev/{service-name}:${NEW_TAG} \
  {account}.dkr.ecr.ap-south-1.amazonaws.com/petclinic-prod/{service-name}:${NEW_TAG}
docker push \
  {account}.dkr.ecr.ap-south-1.amazonaws.com/petclinic-prod/{service-name}:${NEW_TAG}

# Update prod helm-values
yq -i ".image.tag = \"${NEW_TAG}\"" helm-values/prod/{service-name}.yaml
git add helm-values/prod/{service-name}.yaml
git commit -m "deploy: promote {service-name} ${NEW_TAG} to prod"
git push

# Open ArgoCD UI and click Sync on {service-name}-prod
# OR sync via CLI:
aws eks update-kubeconfig --name petclinic-prod --region ap-south-1
kubectl annotate application {service-name}-prod -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite
kubectl patch application {service-name}-prod -n argocd \
  --type merge \
  -p '{"operation":{"sync":{"syncStrategy":{"apply":{"force":false}}}}}'
```

---

## Rollback a Deployment

### Option 1 — GitOps rollback (preferred)

```bash
cd ~/petclinic-infra
git log --oneline helm-values/dev/{service-name}.yaml  # find bad commit
git revert {commit-sha}
git push
# ArgoCD auto-syncs dev within 3 min
# Prod needs manual Sync in ArgoCD UI
```

### Option 2 — Direct tag reset

```bash
# Reset to previous known-good tag
yq -i '.image.tag = "v1.0.0"' helm-values/dev/{service-name}.yaml
git add helm-values/dev/{service-name}.yaml
git commit -m "fix: rollback {service-name} to v1.0.0"
git push

# Force ArgoCD to sync immediately
aws eks update-kubeconfig --name petclinic-dev --region ap-south-1
kubectl annotate application {service-name}-dev -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite
```

### Option 3 — Emergency kubectl rollback

```bash
kubectl rollout undo deployment/{service-name} -n petclinic-dev
```

---

## Access Logs

### Via Grafana (recommended)

https://grafana-dev.praty.dev → Explore → Loki datasource → Query: {namespace="petclinic-dev", app_kubernetes_io_name="{service-name}"}

Useful Loki queries:
{namespace="petclinic-dev"} |= "ERROR"
{namespace="petclinic-dev", app_kubernetes_io_name="vets-service"}
{namespace="petclinic-dev"} |= "HikariPool"
{namespace="petclinic-dev"} |= "Started"

### Via kubectl

```bash
# Current logs
kubectl logs -f deployment/{service-name} -n petclinic-dev

# Previous pod logs (after crash)
kubectl logs deployment/{service-name} -n petclinic-dev --previous

# All pods for a service
kubectl logs -l app.kubernetes.io/name={service-name} \
  -n petclinic-dev --all-containers
```

---

## Check Service Health

```bash
# Full smoke test
./scripts/smoke-test.sh petclinic-dev
./scripts/smoke-test.sh petclinic-prod

# Individual service health
kubectl exec -it deployment/config-server -n petclinic-dev \
  -- wget -qO- http://localhost:8888/actuator/health

# Eureka registrations
kubectl exec -it deployment/discovery-server -n petclinic-dev \
  -- wget -qO- http://localhost:8761/eureka/apps | \
  python3 -c "
import sys
import xml.etree.ElementTree as ET
root = ET.fromstring(sys.stdin.read())
apps = [app.find('name').text for app in root.findall('application')]
print('Registered:', apps)
"

# Check Prometheus targets
kubectl exec -n monitoring \
  $(kubectl get pod -n monitoring -l app=prometheus-server \
  -o jsonpath='{.items[0].metadata.name}') \
  -c prometheus-server \
  -- wget -qO- http://localhost:9090/api/v1/targets 2>/dev/null | \
  python3 -c "
import json,sys
data = json.load(sys.stdin)
for t in data['data']['activeTargets']:
    if 'petclinic' in str(t.get('labels',{})):
        print(t['labels'].get('job'), '→', t['health'])
"
```

---

## ArgoCD Operations

### Force sync an application

```bash
# Hard refresh (re-read Git without applying)
kubectl annotate application {app-name} -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite

# Force sync (apply changes)
kubectl patch application {app-name} -n argocd \
  --type merge \
  -p '{"operation":{"sync":{"syncStrategy":{"apply":{"force":false}}}}}'
```

### Disable/enable auto-sync selfHeal

```bash
# Disable (for chaos demo or manual scaling)
kubectl patch application vets-service-dev -n argocd \
  --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":false}}}}'

# Re-enable
kubectl patch application vets-service-dev -n argocd \
  --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":true}}}}'
```

### Get ArgoCD admin password

```bash
# Dev cluster
aws eks update-kubeconfig --name petclinic-dev --region ap-south-1
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo

# Prod cluster
aws eks update-kubeconfig --name petclinic-prod --region ap-south-1
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

### Sync all prod apps at once

```bash
aws eks update-kubeconfig --name petclinic-prod --region ap-south-1
for APP in config-server-prod discovery-server-prod api-gateway-prod \
           customers-service-prod visits-service-prod vets-service-prod \
           genai-service-prod admin-server-prod; do
  kubectl patch application "${APP}" -n argocd \
    --type merge \
    -p '{"operation":{"sync":{"syncStrategy":{"apply":{"force":false}}}}}' \
    2>/dev/null && echo "Syncing: ${APP}"
done
```

---

## Alertmanager Operations

### Re-inject credentials (after fresh deploy)

```bash
aws eks update-kubeconfig --name petclinic-dev --region ap-south-1

python3 - << 'PYEOF'
import json, subprocess

secret = json.loads(subprocess.check_output([
    "aws", "secretsmanager", "get-secret-value",
    "--secret-id", "petclinic/dev/alertmanager-email",
    "--region", "ap-south-1",
    "--query", "SecretString",
    "--output", "text"
]).decode().strip())

email = secret["email"]
password = secret["app_password"]  # Python preserves spaces — do NOT use shell tr -d ' '

with open("monitoring/alertmanager.yaml") as f:
    content = f.read()

content = content.replace("ALERTMANAGER_EMAIL_PLACEHOLDER", email)
content = content.replace("ALERTMANAGER_PASSWORD_PLACEHOLDER", password)

lines = content.split("\n")
config_lines = []
found = False
for line in lines:
    if "alertmanager.yml: |" in line:
        found = True
        continue
    if found and line.startswith("---"):
        break
    if found:
        config_lines.append(line[4:] if len(line) >= 4 else line)

with open("/tmp/alertmanager-dev.yml", "w") as f:
    f.write("\n".join(config_lines))
print("✅ Config written with password:", password)
PYEOF

kubectl delete secret alertmanager-config -n monitoring 2>/dev/null || true
kubectl create secret generic alertmanager-config \
  -n monitoring \
  --from-file="alertmanager.yml=/tmp/alertmanager-dev.yml"

kubectl rollout restart deployment alertmanager -n monitoring
```

### Check active alerts

```bash
kubectl exec -n monitoring \
  $(kubectl get pod -n monitoring -l app=alertmanager \
  -o jsonpath='{.items[0].metadata.name}') \
  -- wget -qO- http://localhost:9093/api/v2/alerts 2>/dev/null | \
  python3 -c "
import json,sys
alerts = json.load(sys.stdin)
for a in alerts:
    print('ALERT:', a['labels']['alertname'],
          '| State:', a['status']['state'],
          '| Job:', a['labels'].get('job','N/A'))
print('Total:', len(alerts))
"
```

### Fix two alertmanager pods (PVC conflict)

```bash
# Check which replicaset is correct (highest age = current)
kubectl get replicasets -n monitoring | grep alertmanager

# Roll back to correct replicaset
kubectl rollout undo deployment alertmanager -n monitoring
sleep 15
kubectl get pods -n monitoring | grep alertmanager
```

---

## Prod RDS Data Seed (One-Time)

Run ONCE after fresh prod cluster deploy to seed test data:

```bash
aws eks update-kubeconfig --name petclinic-prod --region ap-south-1
./scripts/seed-prod-data.sh
```

---

## Connect to RDS (Debug)

```bash
# Get credentials
kubectl get secret rds-credentials -n petclinic-dev \
  -o jsonpath='{.data.username}' | base64 -d && echo
kubectl get secret rds-credentials -n petclinic-dev \
  -o jsonpath='{.data.password}' | base64 -d && echo

# Run MySQL debug pod inside cluster
kubectl run -it mysql-debug \
  --image=mysql:8 \
  --rm \
  --restart=Never \
  -n petclinic-dev \
  -- mysql \
  -h petclinic-dev-mysql.cbsumcwgg4sm.ap-south-1.rds.amazonaws.com \
  -u petclinic \
  -p petclinic
```

---

## Rotate Secrets

### Alertmanager Gmail app password

```bash
# Update in Secrets Manager
aws secretsmanager update-secret \
  --secret-id "petclinic/dev/alertmanager-email" \
  --secret-string '{"email":"your@gmail.com","app_password":"new xxxx xxxx xxxx xxxx"}' \
  --region ap-south-1

# Also update prod
aws secretsmanager update-secret \
  --secret-id "petclinic/prod/alertmanager-email" \
  --secret-string '{"email":"your@gmail.com","app_password":"new xxxx xxxx xxxx xxxx"}' \
  --region ap-south-1

# Re-inject into cluster (see Alertmanager Operations above)
```

### OpenAI API key

```bash
aws secretsmanager put-secret-value \
  --secret-id petclinic/dev/openai-api-key \
  --secret-string "sk-your-new-key" \
  --region ap-south-1

# Force ESO sync
kubectl annotate externalsecret openai-api-key \
  force-sync=$(date +%s) -n petclinic-dev --overwrite
```

### RDS credentials

```bash
# Force ESO sync after rotation
kubectl annotate externalsecret rds-credentials \
  force-sync=$(date +%s) -n petclinic-dev --overwrite
```

---

## Karpenter Operations

```bash
# Check node provisioning status
kubectl get nodeclaim
kubectl get nodepool

# Check why a pod is Pending (Karpenter should provision a node)
kubectl describe pod {pending-pod-name} -n petclinic-dev | grep -A5 Events

# Force Karpenter to consolidate (scale down idle nodes)
kubectl annotate nodepool default \
  karpenter.sh/do-not-disrupt=false --overwrite 2>/dev/null || true
```

---

## Terraform State Operations

```bash
cd terraform/environments/dev

# List all resources
terraform state list

# Remove stale S3 lock (if terraform output hangs)
aws s3 rm \
  s3://petclinic-terraform-state-482352877891-ap-south-1/petclinic/dev/terraform.tfstate.tflock \
  --region ap-south-1

# Read outputs directly from S3 (bypasses terraform CLI hang)
aws s3 cp \
  s3://petclinic-terraform-state-482352877891-ap-south-1/petclinic/dev/terraform.tfstate \
  /tmp/dev.tfstate --region ap-south-1
python3 -c "
import json
with open('/tmp/dev.tfstate') as f:
    state = json.load(f)
for k,v in state.get('outputs',{}).items():
    print(f'{k} = {v[\"value\"]}')
"

# Import existing resource
terraform import module.vpc.aws_vpc.main vpc-12345678

# Remove from state without destroying
terraform state rm module.vpc.aws_vpc.main
```

---

## Grafana Access

```bash
# Get Grafana admin password
kubectl get secret grafana-admin -n monitoring \
  -o jsonpath='{.data.admin-password}' | base64 -d && echo

# Dev: https://grafana-dev.praty.dev
# Prod: https://grafana.praty.dev
# Login: admin / <password above>
```

### Useful Prometheus Queries

```promql
# Service availability (0 = down, 1 = up)
up{job=~"api-gateway|customers-service|visits-service|vets-service|genai-service"}

# HTTP request rate (per second)
rate(http_server_requests_seconds_count{namespace="petclinic-dev"}[5m])

# P95 latency
histogram_quantile(0.95,
  rate(http_server_requests_seconds_bucket{namespace="petclinic-dev"}[5m]))

# JVM heap usage
jvm_memory_used_bytes{area="heap", namespace="petclinic-dev"}

# Active DB connections
hikaricp_connections_active{namespace="petclinic-dev"}
```

---

## Update EKS Version

```bash
# 1. Check current version
kubectl version --short

# 2. Update in terraform
# Edit terraform/environments/dev/terraform.tfvars:
# eks_cluster_version = "1.31"

# 3. Plan and apply
./scripts/tf.sh dev plan
./scripts/tf.sh dev apply

# 4. Check compatible add-on versions
aws eks describe-addon-versions --kubernetes-version 1.31 \
  --query "addons[].{Name:addonName,Version:addonVersions[0].addonVersion}" \
  --output table
```


