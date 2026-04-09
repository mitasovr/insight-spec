#!/bin/bash
set -euo pipefail

# Local development infrastructure for Insight backend.
# Deploys ClickHouse, MariaDB, and Redis to the local K8s cluster.
#
# Usage:
#   ./local-dev.sh up      — deploy all infrastructure
#   ./local-dev.sh down    — remove all infrastructure
#   ./local-dev.sh status  — show pod status
#
# Prerequisites: kubectl, helm

NAMESPACE="${INSIGHT_NAMESPACE:-default}"

# ── Helm repos ─────────────────────────────────────────────
add_repos() {
    echo "Adding Helm repos..."
    helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
    helm repo add clickhouse-operator https://docs.altinity.com/clickhouse-operator 2>/dev/null || true
    helm repo update
}

# ── MariaDB ────────────────────────────────────────────────
deploy_mariadb() {
    echo "Deploying MariaDB..."
    helm upgrade --install insight-mariadb bitnami/mariadb \
        --namespace "$NAMESPACE" \
        --set auth.rootPassword=insight-root \
        --set auth.database=analytics \
        --set auth.username=insight \
        --set auth.password=insight-pass \
        --set primary.persistence.size=1Gi \
        --set primary.resources.requests.memory=256Mi \
        --set primary.resources.requests.cpu=100m \
        --wait --timeout 120s
    echo "MariaDB ready: mysql://insight:insight-pass@insight-mariadb:3306/analytics"
}

# ── ClickHouse ─────────────────────────────────────────────
deploy_clickhouse() {
    echo "Deploying ClickHouse (official image)..."
    kubectl apply -n "$NAMESPACE" -f - <<'CHEOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: insight-clickhouse
  labels:
    app.kubernetes.io/name: clickhouse
    app.kubernetes.io/instance: insight-clickhouse
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: clickhouse
      app.kubernetes.io/instance: insight-clickhouse
  template:
    metadata:
      labels:
        app.kubernetes.io/name: clickhouse
        app.kubernetes.io/instance: insight-clickhouse
    spec:
      containers:
        - name: clickhouse
          image: clickhouse/clickhouse-server:24.8
          ports:
            - containerPort: 8123
              name: http
            - containerPort: 9000
              name: native
          env:
            - name: CLICKHOUSE_USER
              value: insight
            - name: CLICKHOUSE_PASSWORD
              value: insight-pass
            - name: CLICKHOUSE_DB
              value: insight
          resources:
            requests:
              memory: 512Mi
              cpu: 200m
---
apiVersion: v1
kind: Service
metadata:
  name: insight-clickhouse
  labels:
    app.kubernetes.io/name: clickhouse
    app.kubernetes.io/instance: insight-clickhouse
spec:
  ports:
    - port: 8123
      targetPort: http
      name: http
    - port: 9000
      targetPort: native
      name: native
  selector:
    app.kubernetes.io/name: clickhouse
    app.kubernetes.io/instance: insight-clickhouse
CHEOF
    echo "Waiting for ClickHouse..."
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=insight-clickhouse -n "$NAMESPACE" --timeout=120s
    echo "ClickHouse ready: http://insight:insight-pass@insight-clickhouse:8123"
}

# ── Redis ──────────────────────────────────────────────────
deploy_redis() {
    echo "Deploying Redis..."
    helm upgrade --install insight-redis bitnami/redis \
        --namespace "$NAMESPACE" \
        --set architecture=standalone \
        --set auth.enabled=false \
        --set master.persistence.size=256Mi \
        --set master.resources.requests.memory=64Mi \
        --set master.resources.requests.cpu=50m \
        --wait --timeout 120s
    echo "Redis ready: redis://insight-redis-master:6379"
}

# ── Commands ───────────────────────────────────────────────
up() {
    add_repos
    deploy_mariadb
    deploy_clickhouse
    deploy_redis

    echo ""
    echo "=== Infrastructure ready ==="
    echo ""
    echo "MariaDB:    mysql://insight:insight-pass@insight-mariadb:3306/analytics"
    echo "ClickHouse: http://insight:insight-pass@insight-clickhouse:8123"
    echo "Redis:      redis://insight-redis-master:6379"
    echo ""
    echo "Port-forward for local access:"
    echo "  kubectl port-forward svc/insight-mariadb 3306:3306 &"
    echo "  kubectl port-forward svc/insight-clickhouse 8123:8123 &"
    echo "  kubectl port-forward svc/insight-redis-master 6379:6379 &"
}

down() {
    echo "Removing infrastructure..."
    helm uninstall insight-mariadb --namespace "$NAMESPACE" 2>/dev/null || true
    helm uninstall insight-redis --namespace "$NAMESPACE" 2>/dev/null || true
    # ClickHouse deployed via kubectl, not Helm
    kubectl delete deployment insight-clickhouse -n "$NAMESPACE" 2>/dev/null || true
    kubectl delete svc insight-clickhouse -n "$NAMESPACE" 2>/dev/null || true
    echo "Infrastructure removed."
}

status() {
    echo "=== Infrastructure pods ==="
    kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/instance in (insight-mariadb, insight-clickhouse, insight-redis)" 2>/dev/null || echo "No pods found."
    echo ""
    echo "=== Services ==="
    kubectl get svc -n "$NAMESPACE" -l "app.kubernetes.io/instance in (insight-mariadb, insight-clickhouse, insight-redis)" 2>/dev/null || echo "No services found."
}

# ── Main ───────────────────────────────────────────────────
case "${1:-up}" in
    up)     up ;;
    down)   down ;;
    status) status ;;
    *)      echo "Usage: $0 {up|down|status}" && exit 1 ;;
esac
