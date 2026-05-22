# ArgoCD Installation

ArgoCD is installed by `setup-cluster.sh` as part of the full cluster setup.
It can also be installed standalone using `install-argocd.sh` with pinned version v2.14.3.

---

## Installation (Normal Flow)

ArgoCD is installed automatically as part of the full cluster setup:

```bash
# Dev — ArgoCD installed as part of setup-cluster.sh
./scripts/setup-cluster.sh dev

# Prod — same script, different env
aws eks update-kubeconfig --name petclinic-prod --region ap-south-1
./scripts/setup-cluster.sh prod
```

---

## Installation (Standalone)

If you need to install ArgoCD only, without running the full setup:

```bash
# Dev cluster
aws eks update-kubeconfig --name petclinic-dev --region ap-south-1
./argocd/install/install-argocd.sh

# Prod cluster
aws eks update-kubeconfig --name petclinic-prod --region ap-south-1
./argocd/install/install-argocd.sh --env prod
```

---

## What the Script Does

1. Creates the `argocd` namespace
2. Applies ArgoCD v2.14.3 manifests (pinned — not `stable`)
3. Patches the server to run in `--insecure` mode (TLS terminated at ALB — not in ArgoCD)
4. Waits for all ArgoCD pods to be ready
5. Applies the RBAC ConfigMap (`argocd/argocd-rbac-cm.yaml`)
6. Prints the initial admin password and access URLs

---

## ArgoCD Applications

Applications are defined as ArgoCD `Application` CRDs in:
```
argocd/applications/
├── dev/                    # 9 applications — auto-sync enabled
│   ├── config-server-dev.yaml
│   ├── discovery-server-dev.yaml
│   ├── api-gateway-dev.yaml
│   ├── customers-service-dev.yaml
│   ├── visits-service-dev.yaml
│   ├── vets-service-dev.yaml
│   ├── genai-service-dev.yaml
│   ├── admin-server-dev.yaml
│   └── external-secrets-dev.yaml
└── prod/                   # 9 applications — manual sync required
├── config-server-prod.yaml
├── discovery-server-prod.yaml
├── api-gateway-prod.yaml
├── customers-service-prod.yaml
├── visits-service-prod.yaml
├── vets-service-prod.yaml
├── genai-service-prod.yaml
├── admin-server-prod.yaml
└── external-secrets-prod.yaml
```

Applications are applied automatically by `setup-cluster.sh` after ArgoCD is installed.

---

## Dev vs Prod Sync Behaviour

| Setting | Dev | Prod |
|---------|-----|------|
| Auto-sync | ✅ Enabled | ❌ Disabled |
| selfHeal | ✅ Enabled | ❌ Disabled |
| Prune | ✅ Enabled | ❌ Disabled |
| Sync trigger | Git push → auto within 3 min | Manual click in UI |
| Rollback | Git revert → auto-sync | Git revert → manual Sync |

**Dev auto-sync:** ArgoCD polls the infra Git repo every 3 minutes. When
`helm-values/dev/{service}.yaml` changes (updated by CI pipeline), ArgoCD
detects the drift and automatically deploys the new image. A hard refresh
can trigger immediate sync without waiting 3 minutes:

```bash
kubectl annotate application vets-service-dev -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite
```

**Prod manual sync:** ArgoCD detects changes in `helm-values/prod/` and
shows the app as `OutOfSync`, but does NOT deploy automatically. An operator
must explicitly click **Sync** in the ArgoCD UI or run:

```bash
kubectl patch application vets-service-prod -n argocd \
  --type merge \
  -p '{"operation":{"sync":{"syncStrategy":{"apply":{"force":false}}}}}'
```

---

## Helm Values Structure

Each ArgoCD application loads two value files:

```yaml
valueFiles:
  - ../../helm-values/{env}/{service}.yaml   # service-specific (image tag, ECR URL, env vars)
  - ../../helm-values/{env}.yaml             # environment-wide (replicaCount, resources)
```

The service-specific file takes precedence. The environment-wide file provides
defaults that apply to all services in that environment.

---

## Syncing All Prod Apps (Initial Deploy)

After fresh cluster setup, prod apps start as `OutOfSync`. Sync all at once:

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

sleep 180
./scripts/smoke-test.sh petclinic-prod
```

---

## Access

```bash
# Get admin password (works for both dev and prod clusters)
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

| Method | Dev | Prod |
|--------|-----|------|
| Browser | `https://argocd-dev.praty.dev` | `https://argocd.praty.dev` |
| Port-forward | `kubectl port-forward svc/argocd-server -n argocd 8080:80` | Same |
| Login | `admin` / password above | `admin` / password above |

Port-forward works immediately after install, before DNS is configured.

---

## RBAC

Two roles configured in `argocd/argocd-rbac-cm.yaml`:

| Role | Permissions |
|------|-------------|
| `admin` | Full access — all apps, all environments, settings |
| `developer` | View all apps, sync dev apps only, no prod access, no settings |

```yaml
# argocd/argocd-rbac-cm.yaml
policy.csv: |
  p, role:developer, applications, get,    */*, allow
  p, role:developer, applications, sync,   */dev-*, allow
  p, role:developer, applications, sync,   */external-secrets-dev, allow
  g, developer, role:developer
policy.default: role:readonly
```

---

## Troubleshooting

**App stuck OutOfSync after Git push:**
```bash
# Force hard refresh to re-read Git
kubectl annotate application {app-name} -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite
sleep 15
kubectl patch application {app-name} -n argocd \
  --type merge \
  -p '{"operation":{"sync":{"syncStrategy":{"apply":{"force":false}}}}}'
```

**App Synced but pods not updating:**
```bash
# Check if new image tag was committed to Git
cd ~/petclinic-infra && git pull
grep "tag:" helm-values/dev/{service}.yaml

# Check pod image
kubectl get deployment {service} -n petclinic-dev \
  -o jsonpath='{.spec.template.spec.containers[0].image}' && echo ""
```

**ArgoCD pods not ready after install:**
```bash
kubectl get pods -n argocd
kubectl describe pod -n argocd -l app.kubernetes.io/name=argocd-server | grep -A5 Events
# Common: node not ready — Karpenter provisioning new node, wait 2-3 min
```

**external-secrets app OutOfSync:**
```bash
# Force sync with replace strategy
kubectl patch application external-secrets-{env} -n argocd \
  --type merge \
  -p '{"operation":{"sync":{"syncStrategy":{"apply":{"force":true}}}}}'
```

