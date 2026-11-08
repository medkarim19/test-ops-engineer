#!/bin/bash

echo "CLICKHOUSE DEPLOYMENT - MINIKUBE"

# Start Minikube
echo "Starting Minikube..."

minikube start \
    --driver=docker \
    --memory=2500mb \
    --cpus=2 \
    --ports=30123:30123

# Deploy Kubernetes resources
echo "Deploying Kubernetes resources..."

kubectl apply -f configmap.yaml \
              -f clickhouse-deployment.yaml \
              -f clickhouse-service.yaml

# Wait for the rollout to finish
echo "Waiting for the ClickHouse pod..."

kubectl rollout status statefulset/clickhouse

# Wait until ClickHouse accepts queries
until kubectl exec clickhouse-0 -- clickhouse-client --user root --password root --query "SELECT 1" 2>/dev/null; do
    sleep 3
done

echo "ClickHouse is ready!"

# Create the database
echo "Creating database metrics..."

kubectl exec clickhouse-0 -- clickhouse-client \
    --user root \
    --password root \
    --query "CREATE DATABASE IF NOT EXISTS metrics"

# Create the table
echo "Creating table job_metrics..."

kubectl exec clickhouse-0 -- clickhouse-client \
    --user root \
    --password root \
    --query "CREATE TABLE IF NOT EXISTS metrics.job_metrics (job_id String, timestamp DateTime, duration_sec UInt32, success Bool) ENGINE = MergeTree ORDER BY (job_id, timestamp)"

# Wait until ClickHouse answers over HTTP on the NodePort
echo "Waiting for HTTP on port 30123..."

until curl --silent --fail --max-time 5 http://127.0.0.1:30123/ping 2>/dev/null; do
    sleep 3
done

# Insert the metrics
echo "Inserting 10 metrics..."

python3 send_metrics.py

# Show the total number of rows
echo ""
echo "Total number of rows:"

kubectl exec clickhouse-0 -- clickhouse-client \
    --user root \
    --password root \
    --query "SELECT COUNT(*) FROM metrics.job_metrics"

# Show the last 10 rows
echo ""
echo "Last 10 rows:"

kubectl exec clickhouse-0 -- clickhouse-client \
    --user root \
    --password root \
    --query "SELECT * FROM metrics.job_metrics ORDER BY timestamp DESC LIMIT 10 FORMAT Pretty"

echo ""
echo "Deployment finished."
