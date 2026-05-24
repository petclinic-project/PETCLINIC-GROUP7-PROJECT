# Chaos Engineering Demo Guide

**Total time:** ~15 minutes
**Environment:** Dev only
**Purpose:** Demonstrates platform resilience — service failure detection,
automated alerting, and recovery.

---

## What is Chaos Engineering?

Chaos Engineering is the practice of intentionally introducing failures into
a system to verify that it can withstand unexpected conditions. The goal is
not to break things randomly — it is to build confidence that the platform
behaves correctly under failure conditions before those failures happen in
production.

In this demo, the failure scenario is a service going completely down
(`replicas=0`). This simulates scenarios like:

- A bad deployment that crashes all pods
- An OOM kill taking down all instances
- An operator accidentally scaling a service to zero
- A node failure taking down the only running pod

The platform should detect the failure within 1 minute, fire an alert, send
an email notification, and recover cleanly when the service is restored.

**What we are testing:**

| Component | What is verified |
|-----------|-----------------|
| Prometheus | Detects `up == 0` for vets-service within 1 minute |
| Alertmanager | Routes the `ServiceDown` alert to Gmail via SMTP |
| Gmail | Receives both firing and resolved notifications |
| ArgoCD selfHeal | Disabled during test — verifies it does NOT auto-restore |
| Kubernetes rolling update | New pod starts healthy before old terminates |

---

## Why Dev Only

The chaos demo runs on dev, not prod, for two reasons:

1. Dev has `selfHeal: true` — this is an important part of the demo. After
   manually restoring the service, ArgoCD's selfHeal is re-enabled, showing
   the platform can self-correct future drift automatically.

2. Prod has 2 replicas per service. Scaling to 0 would require more
   coordination and the `ServiceDown` alert only fires when ALL instances
   are down. Dev with 1 replica is simpler and more dramatic.

---

## Browser Tabs — Open Before Starting

| Tab | URL |
|-----|-----|
| Petclinic vets page | `https://petclinic-dev.praty.dev/vets.html` |
| Grafana | `https://grafana-dev.praty.dev` |
| Gmail | `https://mail.google.com` |

The vets page should show a list of veterinarians before the demo starts.
This is the "healthy" baseline that will break and then recover.

---

## Terminal 2 — Keep Running Throughout Demo

```bash
aws eks update-kubeconfig --name petclinic-dev --region ap-south-1
kubectl get pods -n petclinic-dev -w | grep vets
```

This shows pod lifecycle events in real time — termination, pending, and recovery.

---

## Demo Steps

### Step 1 — Show Healthy Baseline

**Terminal 1:**

```bash
aws eks update-kubeconfig --name petclinic-dev --region ap-south-1

echo "=== Current state ==="
kubectl get deployment vets-service -n petclinic-dev
kubectl get pods -n petclinic-dev | grep vets
```

The deployment shows `1/1 READY`. The vets page at
`https://petclinic-dev.praty.dev/vets.html` shows a list of veterinarians.
Prometheus is actively scraping vets-service — the `up` metric is `1`.

---

### Step 2 — Disable ArgoCD selfHeal

```bash
kubectl patch application vets-service-dev -n argocd \
  --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":false}}}}'
```

selfHeal is disabled before scaling to zero. Without this step, ArgoCD would
detect the drift (desired: 1 replica, actual: 0) and immediately restore the
pod — the alert would never fire. Disabling selfHeal simulates a real outage
where ArgoCD is not the cause and cannot auto-recover.

---

### Step 3 — Bring Down vets-service

```bash
kubectl scale deployment vets-service -n petclinic-dev --replicas=0
```

The pod is terminated immediately. Observe:

- **Terminal 2** — pod transitions to `Terminating` then disappears
- **Vets page** — refresh `https://petclinic-dev.praty.dev/vets.html` — the
  veterinarians list fails to load. The api-gateway is still up but
  vets-service is not reachable.
- **Grafana** — open Explore → Prometheus → run:
```promql
  up{job="vets-service"}
```
  Returns `0` — Prometheus has lost the scrape target.

---

### Step 4 — Wait for Alert (3 minutes)

```bash
echo "Waiting 3 minutes for ServiceDown alert to fire..."
sleep 180
```

The `ServiceDown` Prometheus alert rule fires when `up == 0` for more than
1 minute. Alertmanager then routes it to Gmail via SMTP. The 3-minute wait
ensures the alert has fired and the email has been sent.

While waiting, open Grafana → Alerting → Alert Rules → find `ServiceDown`.
The rule state transitions from `Normal` → `Pending` (after 1 min) →
`Firing` (alert sent).

Check Gmail — a `[CRITICAL] Petclinic Alert: ServiceDown` email arrives.
The email body includes the affected service name and the current state.

---

### Step 5 — Verify Alert Fired

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
          '| Job:', a['labels'].get('job',''))
print('Total alerts:', len(alerts))
"
```

Expected output:

ALERT: ServiceDown | State: active | Job: vets-service
Total alerts: 1

This confirms Alertmanager received and processed the alert. The Gmail
notification was sent from this alert.

---

### Step 6 — Restore vets-service

```bash
kubectl scale deployment vets-service -n petclinic-dev --replicas=1
```

Kubernetes schedules a new pod immediately. Observe Terminal 2 — the pod
transitions through `Pending` → `Init` → `Running` → `1/1 Ready`.

The init container waits for config-server and zipkin to be healthy before
the main container starts. Once the readiness probe passes, the pod is added
back to the service endpoints and traffic flows again.

Refresh `https://petclinic-dev.praty.dev/vets.html` — the veterinarians list
returns.

---

### Step 7 — Re-enable selfHeal

```bash
kubectl patch application vets-service-dev -n argocd \
  --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":true}}}}'
```

selfHeal is restored to its normal state. From this point, if anyone
accidentally scales vets-service to zero again, ArgoCD will detect the drift
and restore the pod automatically within 3 minutes — no human intervention
needed.

---

### Step 8 — Wait for Pod Ready

```bash
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=vets-service \
  -n petclinic-dev --timeout=120s
```

---

### Step 9 — Verify Recovery

```bash
echo "=== Final state ==="
kubectl get pods -n petclinic-dev | grep vets
```

The deployment is back to `1/1 READY`. Check Gmail — a second email arrives
with `[1] Resolved` in the subject, confirming Alertmanager detected the
recovery and sent the resolved notification automatically.

Run the smoke test to confirm full platform health:

```bash
./scripts/smoke-test.sh petclinic-dev
```

Expected: 16/16 passed.

---

## Grafana Queries During Demo

Run these in Grafana → Explore → Prometheus to visualise the failure and recovery:

```promql
# Service availability — shows 0 during outage, 1 after recovery
up{job="vets-service"}

# HTTP request rate — drops to 0 during outage
rate(http_server_requests_seconds_count{job="vets-service"}[1m])

# Active alerts
# Use Grafana → Alerting → Alert Rules → ServiceDown
```

---

## Alert Configuration Reference

The `ServiceDown` alert rule in `monitoring/prometheus-values.yaml`:

```yaml
- alert: ServiceDown
  expr: up{job=~"api-gateway|customers-service|visits-service|vets-service|genai-service"} == 0
  for: 1m
  labels:
    severity: critical
  annotations:
    summary: "Service {{ $labels.job }} is DOWN"
    description: "{{ $labels.job }} has been unreachable for more than 1 minute."
```

Alertmanager routes `severity: critical` alerts to Gmail SMTP:
- **Firing email** — sent when alert transitions to active
- **Resolved email** — sent automatically when `up` returns to `1`
  (`send_resolved: true` in alertmanager config)

---

## Demo Summary

```
vets-service scaled to 0
    ↓
Prometheus scrape fails — up{job="vets-service"} = 0
    ↓
Alert rule: up == 0 for > 1 minute → fires ServiceDown
    ↓
Alertmanager routes to Gmail SMTP
    ↓
Email received: [CRITICAL] Petclinic Alert: ServiceDown
    ↓
vets-service scaled back to 1
    ↓
Pod starts → readiness probe passes → traffic restored
    ↓
Prometheus scrape succeeds — up{job="vets-service"} = 1
    ↓
Alertmanager sends resolved notification
    ↓
Email received: [1] Resolved — ServiceDown
```

## Key Design Decisions Demonstrated

| Decision | Implementation |
|----------|---------------|
| Alerting on service availability | Prometheus `up` metric — works for any service without code changes |
| 1-minute alert window | Avoids noise from transient restarts while catching real outages quickly |
| Gmail SMTP | Simple, no additional infrastructure — credentials in Secrets Manager |
| Resolved notifications | `send_resolved: true` closes the alert loop automatically |
| selfHeal separation | ArgoCD selfHeal handles config drift, not service crashes — separate concerns |
| Dev chaos only | Prod has 2 replicas — ServiceDown requires all instances down |


