# ADR-0003: Shared RDS Instance for All Services

**Status:** Accepted
**Date:** 2025

---

## Context

Three services (customers, visits, vets) need MySQL. The application schema has
cross-service foreign key constraints: `visits.pet_id` references `pets.id`
(owned by customers-service). This makes separate databases per service
impractical without significant application changes.

---

## Decision

Single shared `petclinic` database on one RDS instance for all three services.

---

## Consequences

- **Matches application design:** Cross-service FK constraints require a shared DB
- **Simpler operations:** One endpoint, one secret, one backup schedule
- **Lower cost:** One `db.t4g.micro` vs three
- **DB init mode difference between environments:**
  - Dev: `SPRING_SQL_INIT_MODE=always` — seeds test data on every pod startup
  - Prod: `SPRING_SQL_INIT_MODE=never` — prevents re-seeding on restart (schema exists)
  - Fresh prod RDS requires running `./scripts/seed-prod-data.sh` once after first deploy
- **Connection pool constraint (prod):** `db.t4g.micro` has ~60 max connections.
  With 3 services × 2 replicas × default pool of 10 = 60 connections — exactly
  at the limit. `HIKARI_MAXIMUM_POOL_SIZE=5` set in prod helm-values to prevent
  `Too many connections` errors (3 × 2 × 5 = 30 connections — safe headroom).
- **visits-service FK dependency:** visits table has a FK on pets table created
  by customers-service. `setup-cluster.sh` ensures customers-service is healthy
  before visits-service starts, preventing FK constraint violations on fresh deploy.
- In production at scale: separate databases per service with an API layer for
  cross-service data access (DDD bounded contexts)
