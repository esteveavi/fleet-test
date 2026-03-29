#!/usr/bin/env bash
# One-shot bootstrap — see README.md for details on each step.
set -euo pipefail
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERR ]${NC}  $*"; exit 1; }

for cmd in k3d kubectl helm docker git jq; do
  command -v "$cmd" &>/dev/null || error "Missing: $cmd"
done
info "Pre-flight OK."

# Docker network
if docker network inspect k3s-iot &>/dev/null; then
  warn "Network k3s-iot already exists"
else
  docker network create --driver bridge --subnet 172.28.0.0/16 --gateway 172.28.0.1 --label purpose=k3s-iiot k3s-iot
  info "Network created."
fi

# Clusters
for cluster in mgmt edge-pre edge-pro; do
  if k3d cluster list | grep -q "^${cluster}"; then
    warn "Cluster $cluster exists — skipping"
  else
    info "Creating $cluster..."
    k3d cluster create --config "clusters/${cluster}-cluster.yaml"
  fi
done

# Fleet on mgmt
kubectl config use-context k3d-mgmt
helm repo add fleet https://rancher.github.io/fleet-helm-charts/ 2>/dev/null || true
helm repo update fleet
helm upgrade --install fleet-crd fleet/fleet-crd -n cattle-fleet-system --create-namespace --wait
helm upgrade --install fleet fleet/fleet -n cattle-fleet-system \
  --set apiServerURL="https://k3d-mgmt-serverlb:6443" --wait
info "Fleet controller ready."

# Registration token
kubectl create namespace fleet-default --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f fleet/clusters/cluster-groups.yaml
kubectl apply -f fleet/clusters/registration-token.yaml
sleep 10

kubectl get secret edge-token -n fleet-default \
  -o jsonpath='{.data.values}' | base64 -d | tr -d '\r' > edge-values.yaml

kubectl config view --context k3d-mgmt --minify --raw \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d | tr -d '\r' > mgmt-ca.pem

# Register edge clusters
for env in pre pro; do
  kubectl config use-context "k3d-edge-${env}"
  helm upgrade --install fleet-agent fleet/fleet-agent \
    -n cattle-fleet-system --create-namespace \
    -f edge-values.yaml \
    --set-file apiServerCA=mgmt-ca.pem \
    --set labels.fleet-environment=edge \
    --set labels.environment="$env" \
    --wait
  info "edge-$env registered."
done

kubectl config use-context k3d-mgmt

sleep 15
info "All done! Clusters in Fleet:"
kubectl get clusters.fleet.cattle.io -n fleet-default
info "Next: push apps/ to Git, then: kubectl apply -f fleet/gitrepos/iiot-apps.yaml"
