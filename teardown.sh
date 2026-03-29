#!/usr/bin/env bash
set -euo pipefail
k3d cluster delete mgmt edge-pre edge-pro 2>/dev/null || true
docker network rm k3s-iot 2>/dev/null || true
for ctx in k3d-mgmt k3d-edge-pre k3d-edge-pro; do
  kubectl config delete-context "$ctx" 2>/dev/null || true
  kubectl config delete-cluster "$ctx" 2>/dev/null || true
done
echo "Teardown complete."
