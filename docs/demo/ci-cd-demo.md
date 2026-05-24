# CI/CD Demo Guide

**Total time:** ~18 minutes
**Demo service:** vets-service
**Purpose:** Demonstrates the full GitOps pipeline — code push triggers automatic
dev deployment, prod requires explicit manual approval via ArgoCD UI.

---

## Browser Tabs — Open Before Starting

| Tab | URL |
|-----|-----|
| GitHub Actions (app repo) | `https://github.com/paharipratyush/spring-petclinic-microservices/actions` |
| GitHub Actions (infra repo) | `https://github.com/paharipratyush/petclinic-infra/actions` |
| ArgoCD dev | `https://argocd-dev.praty.dev` |
| ArgoCD prod | `https://argocd.praty.dev` |

---

## Pre-Demo Setup

Run this before the demo. Resets both environments to `v1.0.0` for a clean
before/after comparison.

```bash
cd ~/petclinic-infra

# Reset both environments to v1.0.0
yq -i '.image.tag = "v1.0.0"' helm-values/dev/vets-service.yaml
yq -i '.image.tag = "v1.0.0"' helm-values/prod/vets-service.yaml
git add helm-values/dev/vets-service.yaml helm-values/prod/vets-service.yaml
git commit -m "config: reset vets-service to v1.0.0 for demo"
git push

# Deploy v1.0.0 to dev
aws eks update-kubeconfig --name petclinic-dev --region ap-south-1
kubectl annotate application vets-service-dev -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite
sleep 30

echo "=== DEV running ==="
kubectl get deployment vets-service -n petclinic-dev \
  -o jsonpath='{.spec.template.spec.containers[0].image}' && echo ""

# Deploy v1.0.0 to prod
aws eks update-kubeconfig --name petclinic-prod --region ap-south-1
kubectl annotate application vets-service-prod -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite
kubectl patch application vets-service-prod -n argocd \
  --type merge \
  -p '{"operation":{"sync":{"syncStrategy":{"apply":{"force":false}}}}}'
sleep 30

echo "=== PROD running ==="
kubectl get deployment vets-service -n petclinic-prod \
  -o jsonpath='{.spec.template.spec.containers[0].image}' && echo ""

# Clean up any stuck pods
kubectl delete pods -n petclinic-prod \
  $(kubectl get pods -n petclinic-prod \
  --field-selector=status.phase!=Running \
  -o jsonpath='{.items[*].metadata.name}' 2>/dev/null) \
  2>/dev/null || echo "No stuck pods"

sleep 10

# Verify both environments healthy before starting
aws eks update-kubeconfig --name petclinic-dev --region ap-south-1
./scripts/smoke-test.sh petclinic-dev
aws eks update-kubeconfig --name petclinic-prod --region ap-south-1
./scripts/smoke-test.sh petclinic-prod
```

**Expected state:** Both dev and prod running `vets-service:v1.0.0`, both smoke tests 16/16.

---

## Terminal 2 — Keep Running Throughout Demo

```bash
aws eks update-kubeconfig --name petclinic-dev --region ap-south-1
kubectl get pods -n petclinic-dev -w | grep vets
```

This shows the rolling deploy in real time.

---

## Part 1 — Dev CI/CD (Automatic)

### Step 1 — Show Current State

**Terminal 1:**

```bash
aws eks update-kubeconfig --name petclinic-dev --region ap-south-1
cd ~/petclinic-infra

echo "=== BEFORE — Git tag ==="
grep "tag:" helm-values/dev/vets-service.yaml

echo "=== BEFORE — Running image ==="
kubectl get deployment vets-service -n petclinic-dev \
  -o jsonpath='{.spec.template.spec.containers[0].image}' && echo ""
```

Both dev and prod are on `v1.0.0`. This is the baseline before the code change.

---

### Step 2 — Push Code Change

```bash
cd ~/spring-petclinic-microservices
echo "## Performance improvement $(date)" >> \
  spring-petclinic-vets-service/README.md
git add spring-petclinic-vets-service/README.md
git commit -m "feat: improve vets-service performance"
git push
```

The push to `main` triggers `build-push.yml` in GitHub Actions immediately.
The `paths-filter` step detects that only `spring-petclinic-vets-service/`
changed — the other 7 services are not rebuilt.

---

### Step 3 — GitHub Actions Pipeline (~3-4 min)

Watch the pipeline on the **app repo Actions tab**:

| Job | What it does |
|-----|-------------|
| `detect-changes` | Scans changed file paths, outputs a matrix of only the affected services |
| `build` | Builds `linux/arm64` image via QEMU + Buildx, runs Trivy security scan, pushes `vets-service:{sha}` to `petclinic-dev` ECR |
| `notify` | Fires a `repository_dispatch` event to `petclinic-infra` repo with the new SHA and service name |

Then watch the **infra repo Actions tab** — `update-image-tags.yml` triggers
automatically, commits `helm-values/dev/vets-service.yaml` with the new SHA,
and pushes to main. The CI pipeline never touches the cluster directly — it
only updates a file in Git.

---

### Step 4 — Dev Auto-Deployed

**Terminal 1:**

```bash
cd ~/petclinic-infra
git pull

echo "=== AFTER — Git tag (auto-updated by pipeline) ==="
grep "tag:" helm-values/dev/vets-service.yaml

echo "=== PROD tag (unchanged) ==="
grep "tag:" helm-values/prod/vets-service.yaml

# Hard refresh triggers immediate sync instead of waiting 3-min poll
kubectl annotate application vets-service-dev -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite

sleep 30

echo "=== AFTER — Running image ==="
kubectl get deployment vets-service -n petclinic-dev \
  -o jsonpath='{.spec.template.spec.containers[0].image}' && echo ""
```

ArgoCD detected the Git change and performed a rolling deploy automatically.
Prod is still on `v1.0.0` — the CI pipeline only writes to `helm-values/dev/`.
Nothing in this pipeline has access to prod.

Terminal 2 shows the old pod terminating only after the new pod passed its
readiness probe — zero downtime.

---

## Part 2 — Prod CI/CD (Manual Approval)

### Step 5 — Copy Image to Prod ECR

**Terminal 1:**

```bash
cd ~/petclinic-infra
NEW_TAG=$(grep "tag:" helm-values/dev/vets-service.yaml | \
  awk '{print $2}' | tr -d '"')
echo "Promoting: ${NEW_TAG}"

# Login to ECR
aws ecr get-login-password --region ap-south-1 | \
  docker login --username AWS --password-stdin \
  482352877891.dkr.ecr.ap-south-1.amazonaws.com

# Copy image from dev to prod ECR — same binary, no rebuild
docker pull \
  482352877891.dkr.ecr.ap-south-1.amazonaws.com/petclinic-dev/vets-service:${NEW_TAG}
docker tag \
  482352877891.dkr.ecr.ap-south-1.amazonaws.com/petclinic-dev/vets-service:${NEW_TAG} \
  482352877891.dkr.ecr.ap-south-1.amazonaws.com/petclinic-prod/vets-service:${NEW_TAG}
docker push \
  482352877891.dkr.ecr.ap-south-1.amazonaws.com/petclinic-prod/vets-service:${NEW_TAG}
echo "✅ Image promoted to prod ECR"
```

The dev image is copied to prod ECR using `docker pull/tag/push`. No rebuild
happens — the same binary that ran in dev is what gets deployed to prod.
Prod ECR uses IMMUTABLE tags, so once pushed this image cannot be overwritten.

---

### Step 6 — Update Prod Git State

```bash
yq -i ".image.tag = \"${NEW_TAG}\"" helm-values/prod/vets-service.yaml
git add helm-values/prod/vets-service.yaml
git commit -m "deploy: promote vets-service ${NEW_TAG} to prod"
git push

# Switch to prod cluster
aws eks update-kubeconfig --name petclinic-prod --region ap-south-1

# Trigger ArgoCD to detect the change immediately
kubectl annotate application vets-service-prod -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite
```

Updating `helm-values/prod/vets-service.yaml` is the GitOps promotion step.
ArgoCD polls the infra repo and detects that the desired state in Git (new SHA)
differs from the running state in the cluster (v1.0.0) — this is called drift.

---

### Step 7 — Manual Approval in ArgoCD UI

Open **`https://argocd.praty.dev`** and navigate to `vets-service-prod`.

The application shows **OutOfSync** — ArgoCD has detected the drift but has
not deployed automatically. Prod has `automated.selfHeal: false` and
`automated.enabled: false`, meaning every prod deployment requires explicit
operator action.

Click the **DIFF** tab to see exactly what will change — old image tag vs new.

To approve the deployment:
1. Click **SYNC**
2. Leave all defaults
3. Click **SYNCHRONIZE**

**Switch Terminal 2 to prod:**

```bash
aws eks update-kubeconfig --name petclinic-prod --region ap-south-1
kubectl get pods -n petclinic-prod -w | grep vets
```

The rolling deploy follows Kubernetes rolling update strategy — a new pod
starts and must pass its readiness probe before the old pod is terminated.
At no point does the service have zero running instances.

---

### Step 8 — Verify

**Terminal 1:**

```bash
echo "=== Prod now running ==="
kubectl get deployment vets-service -n petclinic-prod \
  -o jsonpath='{.spec.template.spec.containers[0].image}' && echo ""

aws eks update-kubeconfig --name petclinic-dev --region ap-south-1
./scripts/smoke-test.sh petclinic-dev

aws eks update-kubeconfig --name petclinic-prod --region ap-south-1
./scripts/smoke-test.sh petclinic-prod
```

Both environments pass 16/16 smoke test checks.

---

## Pipeline Summary

```
Code push (vets-service README change)
    ↓
GitHub Actions detects only vets-service changed
    ↓
Builds linux/arm64 image + Trivy scan + pushes to petclinic-dev ECR
    ↓
Commits helm-values/dev/vets-service.yaml with new SHA
    ↓
ArgoCD detects Git change → auto-deploys to dev (zero downtime)
    ↓
Operator copies image dev ECR → prod ECR (no rebuild)
    ↓
Operator updates helm-values/prod/vets-service.yaml → commits → pushes
    ↓
ArgoCD detects prod OutOfSync → waits for manual approval
    ↓
Operator clicks Sync in ArgoCD UI
    ↓
ArgoCD rolling deploy to prod (zero downtime)
```

## Key Design Decisions Demonstrated

| Decision | Implementation |
|----------|---------------|
| CI builds once, deploys many | Same image SHA runs in dev and prod |
| No cluster credentials in CI | GitHub Actions uses OIDC — only updates Git files |
| Dev is automatic, prod is manual | ArgoCD auto-sync on dev, manual sync on prod |
| Git is the source of truth | Every deployment traceable to a Git commit |
| Zero downtime deployments | Kubernetes rolling update — readiness probe gates old pod termination |
| Immutable prod images | ECR IMMUTABLE tags prevent overwriting deployed images |

