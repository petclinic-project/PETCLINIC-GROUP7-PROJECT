# Petclinic Platform — Incident Playbook

## Severity Classification

| Severity | Definition | Response Time |
|----------|-----------|--------------|
| SEV1 | Service completely down, users cannot access app | 15 min |
| SEV2 | Degraded performance, partial outage | 1 hour |
| SEV3 | Minor issue, non-critical component affected | Next business day |

---

## Scenario 1: Pod in CrashLoopBackOff

**Symptoms:** Pod repeatedly restarts, `kubectl get pods` shows `CrashLoopBackOff`

**Diagnosis:**
```bash
kubectl get pods -n petclinic-dev
kubectl describe pod {pod-name} -n petclinic-dev
kubectl logs {pod-name} -n petclinic-dev
kubectl logs {pod-name} -n petclinic-dev --previous
```

**Common causes and fixes:**

*Config Server not ready:*
```bash
kubectl exec -it deployment/discovery-server -n petclinic-dev \
  -- wget -qO- http://config-server:8888/actuator/health
# If not healthy:
kubectl rollout restart deployment/config-server -n petclinic-dev
```

*RDS connection failure:*
```bash
kubectl get secret rds-credentials -n petclinic-dev -o yaml
# Check if RDS is accessible — see Scenario 3
```

*OOM (Out of Memory):*
```bash
kubectl top pod {pod-name} -n petclinic-dev
# Increase memory limits in helm-values/dev/{service}.yaml
```

*Init container stuck waiting:*
```bash
# Check which dependency is not ready
kubectl logs {pod-name} -n petclinic-dev -c wait-for-dependencies
# Common: config-server or zipkin not healthy yet
# Fix: wait, or restart config-server/zipkin
```

---

## Scenario 2: Service Not Registering with Eureka

**Symptoms:** API gateway returns 503 for some routes, website tabs show no data

**Diagnosis:**
```bash
kubectl exec -it deployment/discovery-server -n petclinic-dev \
  -- wget -qO- http://localhost:8761/eureka/apps | \
  python3 -c "
import sys, xml.etree.ElementTree as ET
root = ET.fromstring(sys.stdin.read())
apps = [a.find('name').text for a in root.findall('application')]
print('Registered:', apps)
"
```

**Expected registered services:**
`API-GATEWAY, CUSTOMERS-SERVICE, VISITS-SERVICE, VETS-SERVICE, GENAI-SERVICE, ADMIN-SERVER`

**Fix:**
```bash
# Restart the affected service — re-registers on startup
kubectl rollout restart deployment/customers-service -n petclinic-dev
kubectl rollout status deployment/customers-service -n petclinic-dev
# Wait 30-60 seconds after pod Ready for Eureka registration
```

---

## Scenario 3: Database Connection Failures

**Symptoms:** customers/visits/vets services showing errors, 500 on data endpoints, website tabs empty

**Diagnosis:**
```bash
# Check ESO sync status
kubectl get externalsecret rds-credentials -n petclinic-dev
kubectl get secret rds-credentials -n petclinic-dev

# Check service logs for DB errors
kubectl logs deployment/customers-service -n petclinic-dev | grep -i "hikari\|sql\|error"
```

**Fix:**
```bash
# Force ESO sync if secret is missing
kubectl annotate externalsecret rds-credentials \
  force-sync=$(date +%s) -n petclinic-dev --overwrite

# Test connectivity
kubectl run -it mysql-debug --image=mysql:8 --rm --restart=Never \
  -n petclinic-dev -- \
  mysql -h petclinic-dev-mysql.cbsumcwgg4sm.ap-south-1.rds.amazonaws.com \
  -u petclinic -p petclinic -e "SHOW TABLES;"
```

---

## Scenario 4: Prod Website Shows No Data

**Symptoms:** `petclinic.praty.dev` loads but Find Owners / Vets tabs show empty

**Root cause:** Fresh prod RDS has no test data. `SPRING_SQL_INIT_MODE=never`
prevents Spring Boot from seeding data on startup (by design — prevents re-seeding).

**Fix (one-time after fresh deploy):**
```bash
aws eks update-kubeconfig --name petclinic-prod --region ap-south-1
./scripts/seed-prod-data.sh
```

**What seed-prod-data.sh does:**
1. Temporarily sets `SPRING_SQL_INIT_MODE=always` on customers, visits, vets services
2. Waits 90 seconds for pods to restart and seed data
3. Restores `SPRING_SQL_INIT_MODE=never`

**Do NOT run this if prod already has real data** — it will re-seed and may create duplicates.

---

## Scenario 5: Alertmanager Not Sending Emails

**Symptoms:** Service is down but no email received, `Total alerts: 0` from API

**Diagnosis:**
```bash
# Check alertmanager is running
kubectl get pods -n monitoring | grep alertmanager

# Check alertmanager logs for SMTP errors
kubectl logs -n monitoring \
  $(kubectl get pod -n monitoring -l app=alertmanager \
  -o jsonpath='{.items[0].metadata.name}') --tail=20

# Check active alerts
kubectl exec -n monitoring \
  $(kubectl get pod -n monitoring -l app=alertmanager \
  -o jsonpath='{.items[0].metadata.name}') \
  -- wget -qO- http://localhost:9093/api/v2/alerts 2>/dev/null | \
  python3 -c "
import json,sys
alerts = json.load(sys.stdin)
for a in alerts:
    print('ALERT:', a['labels']['alertname'], '| State:', a['status']['state'])
print('Total:', len(alerts))
"

# Verify Prometheus alert rule is active
kubectl exec -n monitoring \
  $(kubectl get pod -n monitoring -l app=prometheus-server \
  -o jsonpath='{.items[0].metadata.name}') \
  -c prometheus-server \
  -- wget -qO- "http://localhost:9090/api/v1/rules" 2>/dev/null | \
  python3 -c "
import json,sys
data = json.load(sys.stdin)
for g in data['data']['groups']:
    for r in g['rules']:
        if 'ServiceDown' in r.get('name',''):
            print('Rule:', r['name'], '| State:', r.get('state',''))
"
```

**Common causes and fixes:**

*Wrong password (spaces stripped):*
```bash
# Verify correct password in Secrets Manager
aws secretsmanager get-secret-value \
  --secret-id petclinic/dev/alertmanager-email \
  --region ap-south-1 \
  --query SecretString --output text | \
  python3 -c "import json,sys; s=json.load(sys.stdin); print('Password:', repr(s['app_password']))"
# Password MUST have spaces: 'kyxc auvf mqvy dmvs'

# If spaces missing — update Secrets Manager
aws secretsmanager update-secret \
  --secret-id "petclinic/dev/alertmanager-email" \
  --secret-string '{"email":"anonym12303@gmail.com","app_password":"kyxc auvf mqvy dmvs"}' \
  --region ap-south-1
```

*Secret overwritten with placeholders (alertmanager.yaml applied manually):*
```bash
# Check if secret has placeholder values
kubectl get secret alertmanager-config -n monitoring \
  -o jsonpath='{.data.alertmanager\.yml}' | base64 -d | grep "smtp_auth_password"
# If shows ALERTMANAGER_PASSWORD_PLACEHOLDER — re-inject credentials
# See runbook: Alertmanager Operations → Re-inject credentials
```

*Alert not firing yet (< 1 min):*
```bash
# ServiceDown alert fires after 1 minute of service being down
# Wait and check again
```

---

## Scenario 6: Two Alertmanager Pods (PVC Conflict)

**Symptoms:** One alertmanager pod stuck in `ContainerCreating`, other running.
Error: `Multi-Attach error for volume — Volume is already used by pod(s)`

**Root cause:** Two replicasets competing for the same PVC. Caused by
running `kubectl apply -f alertmanager.yaml` which triggers a rolling update
while the old pod still holds the PVC.

**Diagnosis:**
```bash
kubectl get pods -n monitoring | grep alertmanager
kubectl get replicasets -n monitoring | grep alertmanager
kubectl describe pod {stuck-pod} -n monitoring | grep -A5 Events
```

**Fix:**
```bash
# Roll back to the single correct replicaset
kubectl rollout undo deployment alertmanager -n monitoring
sleep 15
kubectl get pods -n monitoring | grep alertmanager
# Should show exactly ONE pod Running
```

**Prevention:** `alertmanager.yaml` must NOT contain a `Secret` resource.
The Secret is managed separately by `setup-cluster.sh` to prevent
placeholder overwrite on every `kubectl apply`.

---

## Scenario 7: Image Pull Errors (ImagePullBackOff)

**Symptoms:** Pod stuck in `ImagePullBackOff` or `ErrImagePull`

**Diagnosis:**
```bash
kubectl describe pod {pod-name} -n petclinic-dev | grep -A5 Events
# Look for: "Failed to pull image" or "unauthorized" or "not found"
```

**Fix:**

*Image tag doesn't exist in ECR:*
```bash
# Check if image exists
aws ecr list-images \
  --repository-name petclinic-dev/vets-service \
  --region ap-south-1 | grep {tag}

# If missing — check helm-values has correct tag
grep "tag:" helm-values/dev/vets-service.yaml

# Rebuild and push
./scripts/build-push-images.sh --tag v1.0.0
```

*Prod ECR missing image (not promoted yet):*
```bash
# Check if image exists in prod ECR
aws ecr list-images \
  --repository-name petclinic-prod/vets-service \
  --region ap-south-1

# If missing — image was not promoted from dev to prod
# Follow prod promotion steps in runbook
```

*Node IAM role missing ECR policy:*
```bash
aws iam list-attached-role-policies \
  --role-name petclinic-dev-eks-node-role
# Should include AmazonEC2ContainerRegistryReadOnly
```

---

## Scenario 8: Node Not Ready / Karpenter Issues

**Symptoms:** `kubectl get nodes` shows `NotReady`, pods stuck in `Pending`

**Diagnosis:**
```bash
kubectl get nodes
kubectl describe node {node-name}
kubectl get nodeclaim
kubectl get events -n kube-system --sort-by='.lastTimestamp' | tail -20
```

**Fix:**

*Karpenter node stuck provisioning:*
```bash
# Check nodeclaim status
kubectl describe nodeclaim {nodeclaim-name}
# Common: instance type not available in AZ — Karpenter will retry

# Force delete stuck nodeclaim
kubectl delete nodeclaim {nodeclaim-name}
# Karpenter will create a new one
```

*Managed node NotReady:*
```bash
# Cordon and drain
kubectl cordon {node-name}
kubectl drain {node-name} --ignore-daemonsets --delete-emptydir-data

# Terminate instance — ASG will replace it
aws ec2 terminate-instances --instance-ids {instance-id} --region ap-south-1

# Wait for replacement
kubectl get nodes -w
```

*Cross-SG rules missing (Karpenter nodes can't communicate with managed nodes):*
```bash
# Check security group rules
aws ec2 describe-security-groups \
  --region ap-south-1 \
  --filters "Name=tag:Name,Values=*petclinic-dev*" \
  --query "SecurityGroups[*].{Name:GroupName,Rules:IpPermissions[*]}" \
  --output table
# Fix: ./scripts/tf.sh dev apply (cross-SG rules are in Terraform)
```

---

## Scenario 9: ALB Returns 502 Bad Gateway

**Symptoms:** Website shows 502 after deploy, after DNS change, or after cluster recreate

**Diagnosis:**
```bash
kubectl get ingress -n petclinic-dev
kubectl get ingress -n petclinic-prod
kubectl logs -n kube-system deployment/aws-load-balancer-controller | tail -50

# Check api-gateway pod is running and healthy
kubectl get pods -n petclinic-dev -l app.kubernetes.io/name=api-gateway
kubectl exec -it deployment/api-gateway -n petclinic-dev \
  -- wget -qO- http://localhost:8080/actuator/health
```

**Common causes and fixes:**

*Certificate ARN wrong after recreate:*
```bash
rm -f /tmp/tfstate-dev.json
./scripts/generate-config.sh dev
git add k8s/overlays/dev/ingress.yaml
git commit -m "fix: update cert ARN after cluster recreate" && git push

aws eks update-kubeconfig --name petclinic-dev --region ap-south-1
kubectl apply -f k8s/overlays/dev/ingress.yaml
```

*ALB not created yet (takes 2-5 min after ingress apply):*
```bash
kubectl get ingress petclinic-ingress -n petclinic-dev -w
# Wait until ADDRESS column shows ALB DNS name
```

*DNS not pointing to new ALB after recreate:*
```bash
./scripts/update-dns-and-ingress.sh dev
# Wait 2-5 min for DNS propagation
```

---

## Scenario 10: Terraform Apply Fails

**Symptoms:** `terraform apply` errors, state conflicts, import errors

**Diagnosis and fixes:**

*OIDC provider already exists (409):*
```bash
# Handled automatically by pre-apply-check.sh
./scripts/pre-apply-check.sh dev
./scripts/tf.sh dev apply
```

*Cloudflare CNAME already exists:*
```bash
# Handled automatically by pre-apply-check.sh
# Imports existing record instead of creating
./scripts/pre-apply-check.sh dev
```

*S3 state lock stuck:*
```bash
aws s3 rm \
  s3://petclinic-terraform-state-482352877891-ap-south-1/petclinic/dev/terraform.tfstate.tflock \
  --region ap-south-1
./scripts/tf.sh dev apply
```

*Prod IAM role/policy conflict (shared with dev):*
```bash
# Handled automatically by pre-apply-check.sh
# Imports shared resources instead of re-creating
./scripts/pre-apply-check.sh prod
./scripts/tf.sh prod apply
```

*`terraform output` hangs indefinitely:*
```bash
# Known bug: TLS provider v4.3.0 shutdown issue
# Fix: read state directly from S3 (setup-cluster.sh does this automatically)
aws s3 cp \
  s3://petclinic-terraform-state-482352877891-ap-south-1/petclinic/dev/terraform.tfstate \
  /tmp/tfstate-dev.json --region ap-south-1
# Then proceed — setup-cluster.sh will use this cached file
```

---

## Scenario 11: Docker Buildx Fails (WSL)

**Symptoms:** `build-push-images.sh` fails with:
`bind source path does not exist: /run/desktop/mnt/host/wsl/docker-desktop-bind-mounts/...`

**Root cause:** Docker Desktop restarted, invalidating the buildx builder's
bind mount. The `petclinic-builder` container's mount point no longer exists.

**Fix (automatic):**
`build-push-images.sh` now auto-detects and recreates the builder. Just retry:
```bash
./scripts/build-push-images.sh --tag v1.0.0
```

**Fix (manual if script still fails):**
```bash
docker buildx rm petclinic-builder 2>/dev/null || true
docker buildx create --name petclinic-builder --driver docker-container --use
docker buildx inspect petclinic-builder --bootstrap
./scripts/build-push-images.sh --tag v1.0.0
```

---

## Scenario 12: ArgoCD Shows OutOfSync But Won't Sync

**Symptoms:** App shows OutOfSync in ArgoCD UI, clicking Sync does nothing,
or sync completes but app goes back to OutOfSync immediately

**Diagnosis:**
```bash
kubectl get application {app-name} -n argocd \
  -o jsonpath='{.status.conditions}' | python3 -m json.tool

kubectl get application {app-name} -n argocd \
  -o jsonpath='{.status.sync.status}' && echo ""
```

**Fixes:**

*Helm values file not found:*
```bash
# Verify helm-values paths in ArgoCD application CRD
cat argocd/applications/dev/{app-name}-dev.yaml | grep valueFiles
# Paths must match: ../../helm-values/dev/{service}.yaml
```

*Force sync with prune:*
```bash
kubectl patch application {app-name} -n argocd \
  --type merge \
  -p '{"operation":{"sync":{"syncOptions":["PrunePropagationPolicy=foreground"],"syncStrategy":{"apply":{"force":true}}}}}'
```

*Hard refresh first:*
```bash
kubectl annotate application {app-name} -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite
sleep 15
kubectl patch application {app-name} -n argocd \
  --type merge \
  -p '{"operation":{"sync":{"syncStrategy":{"apply":{"force":false}}}}}'
```

---

## Post-Incident Review Template

```
Date: ___________
Severity: SEV1 / SEV2 / SEV3
Duration: _____ minutes
Services affected: ___________
Environment: dev / prod

Timeline:
  HH:MM — Incident detected
  HH:MM — Investigation started
  HH:MM — Root cause identified
  HH:MM — Fix applied
  HH:MM — Service restored
  HH:MM — Monitoring confirmed recovery

Root cause: ___________

Contributing factors: ___________

Was this preventable? Yes / No
If yes, how: ___________

Action items:
  1. [ ] ___________
  2. [ ] ___________
  3. [ ] ___________

Prevention / follow-up:
  - Script/automation added: ___________
  - Documentation updated: ___________
  - Alert rule added: ___________
```
