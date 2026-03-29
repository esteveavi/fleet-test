# k3s IIoT/OT Multi-Cluster Lab — Rancher Desktop

> **Scope:** Simulate a production-grade IIoT/OT Kubernetes architecture on a single laptop using
> Rancher Desktop + k3d. One **management** cluster drives two **edge** clusters (pre-production and
> production) via **Fleet** (GitOps CD). Every step is documented including network topology,
> certificate SANs, and a full port-by-port security analysis aligned to the **Purdue Model** and
> **Zero Trust** principles.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites & Tool Versions](#2-prerequisites--tool-versions)
3. [Folder & Repository Structure](#3-folder--repository-structure)
4. [Network Design](#4-network-design)
5. [Step 1 — Create the Shared Docker Network](#step-1--create-the-shared-docker-network)
6. [Step 2 — Management Cluster](#step-2--management-cluster)
7. [Step 3 — Edge Pre-Production Cluster](#step-3--edge-pre-production-cluster)
8. [Step 4 — Edge Production Cluster](#step-4--edge-production-cluster)
9. [Step 5 — Certificate Validation](#step-5--certificate-validation)
10. [Step 6 — Install Fleet on Management Cluster](#step-6--install-fleet-on-management-cluster)
11. [Step 7 — Register Edge Clusters with Fleet](#step-7--register-edge-clusters-with-fleet)
12. [Step 8 — Git Repository Layout for Fleet](#step-8--git-repository-layout-for-fleet)
13. [Step 9 — Deploy a Sample IIoT App via Fleet](#step-9--deploy-a-sample-iiot-app-via-fleet)
14. [Step 10 — Verify End-to-End GitOps Flow](#step-10--verify-end-to-end-gitops-flow)
15. [Port Reference — Purdue Model & Zero Trust](#15-port-reference--purdue-model--zero-trust)
16. [Certificate Deep Dive](#16-certificate-deep-dive)
17. [Troubleshooting](#17-troubleshooting)
18. [Teardown](#18-teardown)

---

## 1. Architecture Overview

```
╔══════════════════════════════════════════════════════════════════════════════╗
║  LAPTOP — Rancher Desktop (Docker Engine + k3d)                              ║
║  Docker Network: k3s-iot  172.28.0.0/16                                      ║
║                                                                              ║
║  ┌─────────────────────────────────┐                                         ║
║  │   MANAGEMENT CLUSTER            │  Purdue Level 4 / Enterprise DMZ        ║
║  │   k3d: mgmt                     │                                         ║
║  │                                 │                                         ║
║  │  ┌─────────┐  ┌──────────────┐  │                                         ║
║  │  │  Fleet  │  │   Rancher*   │  │  *optional full Rancher                 ║
║  │  │ Controller  │  (optional)  │  │                                         ║
║  │  └─────────┘  └──────────────┘  │                                         ║
║  │   API :6443   LB :172.28.1.x    │                                         ║
║  └────────────┬────────────────────┘                                         ║
║               │  Fleet Agent pull (mTLS / 443 or 6443)                       ║
║       ┌───────┴────────┐                                                     ║
║       │                │                                                     ║
║  ┌────▼──────────┐  ┌──▼────────────┐                                       ║
║  │ EDGE PRE      │  │ EDGE PRO      │  Purdue Level 3 / Site Operations      ║
║  │ k3d: edge-pre │  │ k3d: edge-pro │                                        ║
║  │               │  │               │                                        ║
║  │ Fleet Agent   │  │ Fleet Agent   │                                        ║
║  │ MQTT Broker   │  │ MQTT Broker   │  IIoT data ingestion                   ║
║  │ OPC-UA GW     │  │ OPC-UA GW     │  OT protocol gateway                   ║
║  │ API :6444     │  │ API :6445     │                                        ║
║  └───────────────┘  └───────────────┘                                       ║
║                                                                              ║
║  ───── All nodes on same Docker bridge ──────────────────────────────────── ║
║  Container-to-container DNS: k3d-mgmt-serverlb, k3d-edge-pre-serverlb, etc. ║
╚══════════════════════════════════════════════════════════════════════════════╝
```

### Cluster responsibilities

| Cluster | Role | Purdue Level | CIDR Pod | CIDR Svc |
|---------|------|-------------|----------|----------|
| `mgmt` | Fleet controller, policy, observability | L4 Enterprise | 10.10.0.0/16 | 10.11.0.0/16 |
| `edge-pre` | Pre-production edge workloads | L3 Site Ops | 10.20.0.0/16 | 10.21.0.0/16 |
| `edge-pro` | Production edge workloads | L3 Site Ops | 10.30.0.0/16 | 10.31.0.0/16 |

---

## 2. Prerequisites & Tool Versions

Install these tools **before** starting. Verified version set:

```
Rancher Desktop  ≥ 1.13  (Docker engine mode, NOT containerd-only)
k3d              ≥ 5.6.3
kubectl          ≥ 1.29
helm             ≥ 3.14
git              any recent
jq               any
openssl          any (for cert inspection)
```

### Install k3d

```bash
# macOS
brew install k3d

# Linux (or WSL2 on Windows)
curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash

# Verify
k3d version
```

### Install helm

```bash
# macOS
brew install helm

# Linux
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

### Rancher Desktop configuration

Open Rancher Desktop → **Preferences → Container Engine** and make sure
`dockerd (moby)` is selected, **not** containerd. Fleet's agent image pull
and kubeconfig merging work best with Docker.

> ⚠️ On **Apple Silicon (M1/M2/M3)** add `--platform linux/amd64` flags only
> if images are not available as multi-arch. All images used here are
> multi-arch, so no special handling is needed.

---

## 3. Folder & Repository Structure

```
k3s-iiot/
├── README.md                    ← this file
├── setup.sh                     ← setup and automation script
├── teardown.sh                  ← teardown and cleanup script
├── edge-values.yaml             ← custom values for edge clusters
├── mgmt-ca.pem                  ← extracted management CA certificate
├── clusters/                    ← k3d cluster config YAML files
│   ├── mgmt-cluster.yaml
│   ├── edge-pre-cluster.yaml
│   └── edge-pro-cluster.yaml
├── fleet/                       ← Fleet registration manifests
│   ├── clusters/
│   │   ├── cluster-groups.yaml
│   │   └── registration-token.yaml
│   └── gitrepos/
│       └── iiot-apps.yaml
└── apps/                        ← GitOps-managed application manifests
    ├── fleet.yaml               ← Fleet bundle root config
    ├── mqtt-broker/
    │   └── fleet.yaml
    └── opcua-gateway/
        ├── deployment.yaml
        └── fleet.yaml
```

Create the skeleton now:

```bash
mkdir -p k3s-iiot/{clusters,fleet/clusters,fleet/gitrepos,apps/mqtt-broker,apps/opcua-gateway}
cd k3s-iiot
```

---

## 4. Network Design

### Why a custom bridge network?

By default each k3d cluster creates its own bridge. Nodes in different clusters
cannot resolve each other by hostname. For the Fleet **agent** (running in edge
clusters) to phone home to the management cluster API server, it must reach it
by name or stable IP.

Solution: create **one** named Docker bridge network and attach all three
clusters to it. k3d sets up an internal DNS entry for each load-balancer
container using the pattern:

```
k3d-<cluster-name>-serverlb
```

So `k3d-mgmt-serverlb` is reachable from any container on the network —
including Fleet agents in edge clusters.

### IP plan

| Container | Role | Approx IP |
|-----------|------|-----------|
| `k3d-mgmt-serverlb` | mgmt API LB | 172.28.0.10 (assigned by Docker) |
| `k3d-mgmt-server-0` | mgmt k3s node | 172.28.0.11 |
| `k3d-edge-pre-serverlb` | edge-pre API LB | 172.28.0.20 |
| `k3d-edge-pre-server-0` | edge-pre k3s node | 172.28.0.21 |
| `k3d-edge-pro-serverlb` | edge-pro API LB | 172.28.0.30 |
| `k3d-edge-pro-server-0` | edge-pro k3s node | 172.28.0.31 |

> IPs are **assigned by Docker DHCP** from the subnet; exact values may differ.
> We capture them with `docker inspect` in the steps below and substitute into
> Fleet registration manifests.

---

## Step 1 — Create the Shared Docker Network

```bash
docker network create \
  --driver bridge \
  --subnet 172.28.0.0/16 \
  --gateway 172.28.0.1 \
  --label purpose=k3s-iiot \
  k3s-iot
```

Verify:

```bash
docker network inspect k3s-iot | jq '.[0].IPAM.Config'
# Expected: [{"Subnet":"172.28.0.0/16","Gateway":"172.28.0.1"}]
```

---

## Step 2 — Management Cluster

### 2.1 Cluster config file

```bash
cat > clusters/mgmt-cluster.yaml << 'EOF'
apiVersion: k3d.io/v1alpha5
kind: Simple
metadata:
  name: mgmt
servers: 1
agents: 0
network: k3s-iot
image: rancher/k3s:v1.29.4-k3s1
options:
  k3d:
    wait: true
    timeout: "120s"
  k3s:
    extraArgs:
      # Give the API server certificate a SAN for the LB container hostname
      # so edge cluster Fleet agents can verify TLS
      - arg: "--tls-san=k3d-mgmt-serverlb"
        nodeFilters: ["server:*"]
      - arg: "--tls-san=172.28.0.0/16"
        nodeFilters: ["server:*"]
      # Separate CIDRs per cluster to avoid routing conflicts
      - arg: "--cluster-cidr=10.10.0.0/16"
        nodeFilters: ["server:*"]
      - arg: "--service-cidr=10.11.0.0/16"
        nodeFilters: ["server:*"]
      # Disable default traefik — we manage ingress ourselves
      - arg: "--disable=traefik"
        nodeFilters: ["server:*"]
      # Enable cluster labels for Fleet targeting
      - arg: "--node-label=cluster-role=management"
        nodeFilters: ["server:*"]
      - arg: "--node-label=environment=management"
        nodeFilters: ["server:*"]
  kubeconfig:
    updateDefaultKubeconfig: true
    switchCurrentContext: true
ports:
  # Expose API server on host for kubectl
  - port: "6443:6443"
    nodeFilters: ["loadbalancer"]
EOF
```

### 2.2 Create the cluster

```bash
k3d cluster create --config clusters/mgmt-cluster.yaml
```

Expected output (abridged):

```
INFO[...] Creating cluster 'mgmt'
INFO[...] Creating network 'k3s-iot' ... (already exists, reusing)
INFO[...] Creating node 'k3d-mgmt-server-0'
INFO[...] Creating LoadBalancer 'k3d-mgmt-serverlb'
INFO[...] Cluster 'mgmt' created successfully!
INFO[...] kubeconfig updated — current context: k3d-mgmt
```

### 2.3 Verify

```bash
kubectl config use-context k3d-mgmt
kubectl get nodes -o wide
# NAME                  STATUS   ROLES                  AGE   VERSION
# k3d-mgmt-server-0    Ready    control-plane,master   ...   v1.29.x
```

### 2.4 Capture management LB IP (needed later for Fleet)

```bash
MGMT_LB_IP=$(docker inspect k3d-mgmt-serverlb \
  --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
echo "Management LB IP: $MGMT_LB_IP"
# e.g. 172.28.0.10
```

Save it — you'll need it when registering edge clusters.

---

## Step 3 — Edge Pre-Production Cluster

### 3.1 Cluster config file

```bash
cat > clusters/edge-pre-cluster.yaml << 'EOF'
apiVersion: k3d.io/v1alpha5
kind: Simple
metadata:
  name: edge-pre
servers: 1
agents: 0
network: k3s-iot
image: rancher/k3s:v1.29.4-k3s1
options:
  k3d:
    wait: true
    timeout: "120s"
  k3s:
    extraArgs:
      - arg: "--tls-san=k3d-edge-pre-serverlb"
        nodeFilters: ["server:*"]
      - arg: "--cluster-cidr=10.20.0.0/16"
        nodeFilters: ["server:*"]
      - arg: "--service-cidr=10.21.0.0/16"
        nodeFilters: ["server:*"]
      - arg: "--disable=traefik"
        nodeFilters: ["server:*"]
      # Fleet uses these labels for bundle targeting
      - arg: "--node-label=cluster-role=edge"
        nodeFilters: ["server:*"]
      - arg: "--node-label=environment=pre"
        nodeFilters: ["server:*"]
  kubeconfig:
    updateDefaultKubeconfig: true
    switchCurrentContext: false   # keep mgmt as default
ports:
  - port: "6444:6443"
    nodeFilters: ["loadbalancer"]
EOF
```

### 3.2 Create the cluster

```bash
k3d cluster create --config clusters/edge-pre-cluster.yaml
```

### 3.3 Verify (switch context temporarily)

```bash
kubectl config use-context k3d-edge-pre
kubectl get nodes
# k3d-edge-pre-server-0    Ready    control-plane,master   ...

# Return to mgmt context
kubectl config use-context k3d-mgmt
```

---

## Step 4 — Edge Production Cluster

### 4.1 Cluster config file

```bash
cat > clusters/edge-pro-cluster.yaml << 'EOF'
apiVersion: k3d.io/v1alpha5
kind: Simple
metadata:
  name: edge-pro
servers: 1
agents: 0
network: k3s-iot
image: rancher/k3s:v1.29.4-k3s1
options:
  k3d:
    wait: true
    timeout: "120s"
  k3s:
    extraArgs:
      - arg: "--tls-san=k3d-edge-pro-serverlb"
        nodeFilters: ["server:*"]
      - arg: "--cluster-cidr=10.30.0.0/16"
        nodeFilters: ["server:*"]
      - arg: "--service-cidr=10.31.0.0/16"
        nodeFilters: ["server:*"]
      - arg: "--disable=traefik"
        nodeFilters: ["server:*"]
      - arg: "--node-label=cluster-role=edge"
        nodeFilters: ["server:*"]
      - arg: "--node-label=environment=pro"
        nodeFilters: ["server:*"]
  kubeconfig:
    updateDefaultKubeconfig: true
    switchCurrentContext: false
ports:
  - port: "6445:6443"
    nodeFilters: ["loadbalancer"]
EOF
```

### 4.2 Create the cluster

```bash
k3d cluster create --config clusters/edge-pro-cluster.yaml
```

### 4.3 Verify all three clusters

```bash
k3d cluster list
# NAME       SERVERS   AGENTS   LOADBALANCER
# mgmt       1/1       0/0      true
# edge-pre   1/1       0/0      true
# edge-pro   1/1       0/0      true

kubectl config get-contexts
# k3d-mgmt       *
# k3d-edge-pre
# k3d-edge-pro
```

---

## Step 5 — Certificate Validation

k3s generates its own CA and signs the API server certificate automatically.
Before registering edge clusters, verify that the TLS SAN we specified is
present and that cross-cluster TLS works.

### 5.1 Inspect the management cluster API cert

```bash
# Dump the cert from the live API server
openssl s_client \
  -connect k3d-mgmt-serverlb:6443 \
  -showcerts \
  -servername k3d-mgmt-serverlb \
  </dev/null 2>/dev/null \
  | openssl x509 -noout -text \
  | grep -A5 "Subject Alternative Name"
```

You should see SANs including:
```
DNS: k3d-mgmt-server-0
DNS: k3d-mgmt-serverlb        ← added by --tls-san
IP:  127.0.0.1
IP:  10.11.0.1                ← service CIDR gateway
IP:  <node LAN IP>
```

> If `k3d-mgmt-serverlb` is **not** listed: the cluster was created without the
> `--tls-san` arg. Destroy and recreate: `k3d cluster delete mgmt`.

### 5.2 Test cross-cluster reachability

Run a temporary pod **inside** the edge-pre cluster and curl the mgmt API:

```bash
kubectl config use-context k3d-edge-pre

kubectl run cert-test \
  --image=curlimages/curl:latest \
  --restart=Never \
  --rm -it \
  -- sh -c "curl -sk https://k3d-mgmt-serverlb:6443/healthz && echo OK"
# Expected: ok
```

> `-sk` skips host verification here for the quick test. Fleet uses the full
> CA bundle, so TLS is properly verified at agent startup.

```bash
kubectl config use-context k3d-mgmt
```

### 5.3 Export each cluster's CA for cross-trust (optional hardening)

```bash
# Extract mgmt CA cert
kubectl config use-context k3d-mgmt
kubectl get secret \
  -n kube-system k3s-serving \
  -o jsonpath='{.data.tls\.crt}' \
  | base64 -d > certs/mgmt-ca.crt

# Repeat for edge clusters
kubectl config use-context k3d-edge-pre
kubectl get secret \
  -n kube-system k3s-serving \
  -o jsonpath='{.data.tls\.crt}' \
  | base64 -d > certs/edge-pre-ca.crt

kubectl config use-context k3d-edge-pro
kubectl get secret \
  -n kube-system k3s-serving \
  -o jsonpath='{.data.tls\.crt}' \
  | base64 -d > certs/edge-pro-ca.crt

kubectl config use-context k3d-mgmt
```

---

## Step 6 — Install Fleet on Management Cluster

Fleet is Rancher's pull-based GitOps engine. We install the standalone version
(no full Rancher required).

```bash
kubectl config use-context k3d-mgmt

# Add Fleet Helm repo
helm repo add fleet https://rancher.github.io/fleet-helm-charts/
helm repo update

# Install Fleet CRDs first (required)
helm install fleet-crd fleet/fleet-crd \
  --namespace cattle-fleet-system \
  --create-namespace \
  --wait

# Install Fleet controller
helm install fleet fleet/fleet \
  --namespace cattle-fleet-system \
  --set apiServerURL="https://k3d-mgmt-serverlb:6443" \
  --wait
```

> `apiServerURL` must use the hostname that edge agents will reach. We use the
> LB container hostname which is resolvable inside the Docker network.

### 6.1 Verify Fleet controller

```bash
kubectl -n cattle-fleet-system get pods
# NAME                                READY   STATUS    RESTARTS
# fleet-controller-xxxxxxxxx-xxxxx   1/1     Running   0
# gitjob-xxxxxxxxx-xxxxx             1/1     Running   0

kubectl -n cattle-fleet-system get gitrepo   # empty until we add repos
kubectl get clusters.fleet.cattle.io -A      # empty until edge clusters register
```

---

## Step 7 — Register Edge Clusters with Fleet

Fleet uses a **ClusterRegistrationToken** on the management cluster and a
**fleet-agent** Helm chart deployed on each edge cluster. The agent polls the
management API and pulls bundle updates.

### 7.1 Create a ClusterGroup and registration tokens

```bash
# ── ClusterGroup: all-edge ──────────────────────────────────────────────────
cat > fleet/clusters/cluster-groups.yaml << 'EOF'
apiVersion: fleet.cattle.io/v1alpha1
kind: ClusterGroup
metadata:
  name: edge-clusters
  namespace: fleet-default
spec:
  selector:
    matchLabels:
      fleet-environment: edge
EOF

kubectl apply -f fleet/clusters/cluster-groups.yaml
```

### 7.2 Create registration token

```bash
cat > fleet/clusters/registration-token.yaml << 'EOF'
apiVersion: fleet.cattle.io/v1alpha1
kind: ClusterRegistrationToken
metadata:
  name: edge-token
  namespace: fleet-default
spec:
  ttl: 0h   # 0 = never expires; use "24h" in real environments
EOF

kubectl apply -f fleet/clusters/registration-token.yaml

# Wait a moment then retrieve the token value
sleep 5
FLEET_TOKEN=$(kubectl get secret \
  -n fleet-default \
  -l "fleet.cattle.io/cluster-registration-token=edge-token" \
  -o jsonpath='{.items[0].data.values}' \
  | base64 -d)
echo "$FLEET_TOKEN" | head -5
```

### 7.3 Install fleet-agent on edge-pre

```bash
kubectl config use-context k3d-edge-pre

# Get the management API URL as seen from inside Docker network
MGMT_API="https://k3d-mgmt-serverlb:6443"

# Get management CA data (base64)
MGMT_CA=$(kubectl config view \
  --context k3d-mgmt \
  --minify \
  --raw \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

# Install fleet-agent Helm chart
helm install fleet-agent fleet/fleet-agent \
  --namespace cattle-fleet-system \
  --create-namespace \
  --set apiServerURL="$MGMT_API" \
  --set apiServerCA="$MGMT_CA" \
  --set token="$FLEET_TOKEN" \
  --set clusterNamespace="fleet-default" \
  --set labels.fleet-environment=edge \
  --set labels.environment=pre \
  --set labels.region=barcelona \
  --wait
```

### 7.4 Install fleet-agent on edge-pro

```bash
kubectl config use-context k3d-edge-pro

helm install fleet-agent fleet/fleet-agent \
  --namespace cattle-fleet-system \
  --create-namespace \
  --set apiServerURL="$MGMT_API" \
  --set apiServerCA="$MGMT_CA" \
  --set token="$FLEET_TOKEN" \
  --set clusterNamespace="fleet-default" \
  --set labels.fleet-environment=edge \
  --set labels.environment=pro \
  --set labels.region=barcelona \
  --wait
```

### 7.5 Verify edge clusters appear in Fleet

```bash
kubectl config use-context k3d-mgmt

kubectl get clusters.fleet.cattle.io -n fleet-default
# NAME                           BUNDLES-READY   NODES-READY   SAMPLE-NODE
# cluster-edge-pre-xxxxxxxxxx    0               1             k3d-edge-pre-server-0
# cluster-edge-pro-xxxxxxxxxx    0               1             k3d-edge-pro-server-0

kubectl get clustergroups.fleet.cattle.io -n fleet-default
# NAME           CLUSTERS-READY   BUNDLES-READY
# edge-clusters  2                0
```

Both clusters should be **Ready**. Fleet agent TLS is verified using the CA
data we passed in `apiServerCA` — no `--insecure` flags anywhere.

---

## Step 8 — Git Repository Layout for Fleet

Fleet watches a Git repo and applies manifests to target clusters based on
label selectors. Push the `apps/` folder to your Git host.

### 8.1 Root fleet.yaml (targets all edge bundles)

```bash
cat > apps/fleet.yaml << 'EOF'
# Root bundle — Fleet reads this to discover sub-bundles.
# Each sub-directory with its own fleet.yaml is a separate bundle.
defaultNamespace: iiot-workloads
EOF
```

### 8.2 MQTT Broker bundle

```bash
# fleet.yaml — bundle-level targeting
cat > apps/mqtt-broker/fleet.yaml << 'EOF'
defaultNamespace: mqtt-system
helm:
  releaseName: emqx
  chart: emqx
  repo: https://repos.emqx.io/charts
  version: "5.6.0"
  values:
    replicaCount: 1
    service:
      type: ClusterIP
    emqxConfig:
      EMQX_LOG__CONSOLE_HANDLER__ENABLE: "true"
      EMQX_AUTHENTICATION__1__MECHANISM: "password_based"

# Target: both edge clusters
targets:
  - name: edge-pre
    clusterSelector:
      matchLabels:
        environment: pre
        fleet-environment: edge
    helm:
      values:
        emqxConfig:
          EMQX_NODE__NAME: "emqx@emqx-pre.mqtt-system.svc.cluster.local"
  - name: edge-pro
    clusterSelector:
      matchLabels:
        environment: pro
        fleet-environment: edge
    helm:
      values:
        emqxConfig:
          EMQX_NODE__NAME: "emqx@emqx-pro.mqtt-system.svc.cluster.local"
EOF
```

### 8.3 OPC-UA Gateway bundle

```bash
cat > apps/opcua-gateway/namespace.yaml << 'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: opcua-system
  labels:
    app.kubernetes.io/managed-by: fleet
EOF

cat > apps/opcua-gateway/deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: opcua-gateway
  namespace: opcua-system
  labels:
    app: opcua-gateway
spec:
  replicas: 1
  selector:
    matchLabels:
      app: opcua-gateway
  template:
    metadata:
      labels:
        app: opcua-gateway
    spec:
      containers:
        - name: gateway
          image: ghcr.io/node-opcua/node-opcua-sample-server:latest
          ports:
            - name: opcua
              containerPort: 4840    # OPC-UA default port
              protocol: TCP
          env:
            - name: OPCUA_PORT
              value: "4840"
          resources:
            requests:
              cpu: "50m"
              memory: "64Mi"
            limits:
              cpu: "200m"
              memory: "256Mi"
---
apiVersion: v1
kind: Service
metadata:
  name: opcua-gateway
  namespace: opcua-system
spec:
  selector:
    app: opcua-gateway
  ports:
    - name: opcua
      port: 4840
      targetPort: 4840
  type: ClusterIP
EOF

cat > apps/opcua-gateway/fleet.yaml << 'EOF'
defaultNamespace: opcua-system
# Deploy to ALL edge clusters
targets:
  - name: all-edge
    clusterSelector:
      matchLabels:
        fleet-environment: edge
    # Environment-specific overrides via kustomize patches
    kustomize:
      patches:
        - patch: |-
            - op: replace
              path: /spec/template/spec/containers/0/env/0/value
              value: "4840"
          target:
            kind: Deployment
            name: opcua-gateway
EOF
```

### 8.4 Push to Git

```bash
cd k3s-iiot
git init
git add .
git commit -m "feat: initial IIoT multi-cluster Fleet configuration"

# Push to your Git host (GitHub / GitLab / Gitea)
git remote add origin https://github.com/<your-org>/k3s-iiot-apps.git
git push -u origin main
```

---

## Step 9 — Deploy a Sample IIoT App via Fleet

### 9.1 Create GitRepo resources on the management cluster

```bash
kubectl config use-context k3d-mgmt

cat > fleet/gitrepos/iiot-apps.yaml << 'EOF'
apiVersion: fleet.cattle.io/v1alpha1
kind: GitRepo
metadata:
  name: iiot-apps
  namespace: fleet-default
spec:
  repo: https://github.com/<your-org>/k3s-iiot-apps.git
  branch: main
  # Path inside the repo where Fleet bundles live
  paths:
    - apps/mqtt-broker
    - apps/opcua-gateway
  # Deploy to all registered edge clusters
  targets:
    - name: all-edge
      clusterSelector:
        matchLabels:
          fleet-environment: edge
  # Poll interval
  pollingInterval: 30s
  # For private repos add a secret:
  # clientSecretName: git-credentials
EOF

kubectl apply -f fleet/gitrepos/iiot-apps.yaml
```

### 9.2 Watch rollout progress

```bash
# Fleet bundle status
kubectl get bundles -n fleet-default -w

# Cluster-level bundle deployments
kubectl get bundledeployments -A

# Check on edge-pre
kubectl config use-context k3d-edge-pre
kubectl get pods -n mqtt-system
kubectl get pods -n opcua-system

# Check on edge-pro
kubectl config use-context k3d-edge-pro
kubectl get pods -n mqtt-system
kubectl get pods -n opcua-system
```

### 9.3 GitOps update cycle

1. Edit `apps/mqtt-broker/fleet.yaml` on your machine
2. `git commit -am "chore: update EMQX version to 5.7.0"` + `git push`
3. Within ≤30 seconds Fleet polls and applies the diff to both edge clusters
4. Validate: `kubectl get bundles -n fleet-default`

---

## Step 10 — Verify End-to-End GitOps Flow

```bash
# 1. All clusters healthy
kubectl config use-context k3d-mgmt
kubectl get clusters.fleet.cattle.io -n fleet-default

# 2. GitRepo synced (READY should be True)
kubectl get gitrepo -n fleet-default
# NAME         REPO                              COMMIT   BUNDLEDEPLOYMENTS-READY
# iiot-apps    https://github.com/.../iiot...    abc1234  2/2

# 3. Bundles ready across edge clusters
kubectl get bundles -n fleet-default
# NAME                              BUNDLEDEPLOYMENTS-READY   STATUS
# iiot-apps-mqtt-broker             2/2                       Ready
# iiot-apps-opcua-gateway           2/2                       Ready

# 4. Pods running on edge-pre
kubectl config use-context k3d-edge-pre
kubectl get pods -A | grep -E 'mqtt|opcua'

# 5. Pods running on edge-pro
kubectl config use-context k3d-edge-pro
kubectl get pods -A | grep -E 'mqtt|opcua'
```

---

## 15. Port Reference — Purdue Model & Zero Trust

This section is the **security reference** for OT/IT network segmentation.
Every port listed below must be explicitly allowed in firewall/ACL rules and
denied by default everywhere else (Zero Trust default-deny posture).

### Purdue Model Level Mapping

```
┌──────────────────────────────────────────────────┐
│  LEVEL 5 — Enterprise IT / Cloud               │
│  (not in scope for this lab)                   │
├──────────────────────────────────────────────────┤
│  LEVEL 4 — Site Business Planning              │
│  → Management Cluster (mgmt)                   │
│    Fleet controller, policy engine, observability│
├──────────────────────────────────────────────────┤
│  LEVEL 3.5 — Industrial DMZ / Demilitarized    │
│  → Strict firewall between L4 ↔ L3            │
│    Only Fleet agent pull allowed (6443 outbound)│
├──────────────────────────────────────────────────┤
│  LEVEL 3 — Site Operations                     │
│  → Edge clusters (edge-pre, edge-pro)          │
│    MQTT broker, OPC-UA gateway                 │
├──────────────────────────────────────────────────┤
│  LEVEL 2 — Area Supervisory Control            │
│  → SCADA / HMI systems (not Kubernetes)        │
│    Connect to OPC-UA gateway on port 4840      │
├──────────────────────────────────────────────────┤
│  LEVEL 1 — Basic Control                       │
│  → PLCs, RTUs: publish MQTT to edge broker    │
├──────────────────────────────────────────────────┤
│  LEVEL 0 — Physical Process / Field Devices   │
│  → Sensors, actuators (hardware)              │
└──────────────────────────────────────────────────┘
```

---

### Port Table — Management Cluster (Purdue L4)

| Port | Protocol | Direction | From | To | Purpose | Open? | Zero Trust note |
|------|----------|-----------|------|----|---------|-------|-----------------|
| **6443** | TCP | Inbound | Edge Fleet agents (L3) | mgmt API LB | Kubernetes API server — agents pull config | ✅ Required | Only Fleet agent service accounts; mTLS; no anonymous auth |
| **6443** | TCP | Inbound | Admin workstation | mgmt API LB | `kubectl` management access | ✅ Required | Restrict by source IP or VPN; RBAC enforced |
| **2379** | TCP | Internal | mgmt server-0 | mgmt server-0 | etcd client API | ✅ Internal only | Never expose outside node; loopback only |
| **2380** | TCP | Internal | mgmt server-0 | mgmt server-0 | etcd peer replication | ✅ Internal only | Single-node: unused; multi-node: node-to-node only |
| **8472** | UDP | Internal | flannel VXLAN | pod-to-pod | Flannel overlay CNI encapsulation | ✅ Internal only | Node-to-node only within cluster CIDR |
| **10250** | TCP | Internal | mgmt server | kubelet | Kubelet API (metrics, logs, exec) | ✅ Node-local | Never expose externally; used by API server only |
| **10251** | TCP | Internal | API server | kube-scheduler | Scheduler healthz | ✅ Internal only | Loopback only |
| **10252** | TCP | Internal | API server | kube-controller | Controller-manager healthz | ✅ Internal only | Loopback only |
| **51820** | UDP | Internal | WireGuard | node-to-node | Optional WireGuard CNI (not used here) | ❌ Disabled | Enable only if replacing Flannel with WireGuard overlay |
| **443** | TCP | Outbound | Fleet controller | Git host | Fleet polls Git repo | ✅ Outbound | Allowlist specific Git host IP/domain; TLS verified |
| **80** | TCP | Inbound | Admin browser | Rancher UI | Rancher web console (if installed) | ⚠️ Redirect | Redirect to 443; never leave plain HTTP open |
| **443** | TCP | Inbound | Admin browser | Rancher UI | Rancher web console HTTPS | ✅ If Rancher | Restrict by source IP; OAuth2/OIDC auth |

---

### Port Table — Edge Clusters (Purdue L3) — applies to both edge-pre and edge-pro

| Port | Protocol | Direction | From | To | Purpose | Open? | Zero Trust note |
|------|----------|-----------|------|----|---------|-------|-----------------|
| **6443** | TCP | Outbound | Fleet agent pod | mgmt API LB :6443 | Agent pulls bundle updates from management | ✅ Required | Egress only; mTLS; agent uses cluster-scoped token |
| **6443** | TCP | Inbound | Admin workstation | edge API LB | `kubectl` debug access (edge-pre: :6444, edge-pro: :6445) | ⚠️ Dev only | Production: remove host port mapping; use tunnel |
| **8472** | UDP | Internal | flannel | node-to-node | Flannel VXLAN pod overlay | ✅ Internal only | Never cross-cluster; each cluster has its own CIDR |
| **10250** | TCP | Internal | API server | kubelet | Kubelet API | ✅ Node-local | Loopback / cluster-internal only |
| **1883** | TCP | Inbound | PLCs / RTUs (L1) | MQTT broker pod | MQTT plain-text (Level 1 devices) | ⚠️ L1→L3 only | Should be TLS (8883) wherever device supports it |
| **8883** | TCP | Inbound | PLCs / RTUs (L1) | MQTT broker pod | MQTT over TLS (preferred) | ✅ Preferred | Mutual TLS where feasible; ACL per topic |
| **18083** | TCP | Inbound | Ops team (L4) | EMQX Dashboard | EMQX web UI | ⚠️ Restricted | Bind to mgmt VLAN only; enforce login |
| **4840** | TCP | Inbound | SCADA/HMI (L2) | OPC-UA gateway pod | OPC-UA binary protocol (no TLS) | ⚠️ L2→L3 | Allowlist SCADA IP; use OPC-UA Security Mode Sign+Encrypt where possible |
| **4843** | TCP | Inbound | SCADA/HMI (L2) | OPC-UA gateway pod | OPC-UA over TLS | ✅ Preferred | Enforce certificate-based auth |
| **30000-32767** | TCP/UDP | Inbound | L2 systems | NodePort svc | Kubernetes NodePort services | ⚠️ Minimize | Prefer ClusterIP + ingress; each NodePort is an attack surface |
| **9090** | TCP | Internal | Prometheus | metrics endpoint | Prometheus scrape (if deployed) | ✅ Internal only | ClusterIP only; no external exposure |
| **9091** | TCP | Outbound | Prometheus agent | mgmt Prometheus | Remote-write metrics to central (if configured) | Optional | mTLS remote-write; allowlist only central Prometheus IP |

---

### Zero Trust Rules Summary

```
RULE 1 — Default deny inbound on ALL ports at all levels.
         Explicit allow only.

RULE 2 — Fleet agent communication is OUTBOUND ONLY from edge clusters.
         Management cluster never initiates connections to edge clusters.
         (Pull model = Zero Trust compliant)

RULE 3 — Edge-pre ↔ Edge-pro: NO lateral traffic allowed.
         Separate Docker subnets + NetworkPolicy enforce this.

RULE 4 — Cross-Purdue-level traffic (L1→L3, L2→L3, L3→L4) must cross
         an explicit firewall rule. No level can reach two levels up
         without traversing the DMZ.

RULE 5 — All Kubernetes API (6443) traffic must use TLS.
         k3s self-signed CA + SAN-verified certs. No --insecure-skip-tls-verify.

RULE 6 — MQTT plain (1883) is tolerated ONLY for L0/L1 devices that cannot
         do TLS. Enforce at EMQX ACL layer: device A cannot subscribe to
         device B's topic. Use dedicated VLANs.

RULE 7 — etcd (2379, 2380) must NEVER be reachable outside the node.
         k3s embeds etcd; default bind is 127.0.0.1 ✅

RULE 8 — Fleet GitRepo polling uses HTTPS (443) outbound only.
         Git credentials stored in Kubernetes Secrets, not in YAML files.
```

---

### NetworkPolicy — isolate edge-pre from edge-pro

Apply this on **both** edge clusters to make the Zero Trust isolation explicit
at the Kubernetes level (in addition to Docker network segmentation):

```bash
# Apply on edge-pre
kubectl config use-context k3d-edge-pre
kubectl apply -f - << 'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-cross-cluster
  namespace: default
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
  ingress:
    # Allow only intra-namespace traffic
    - from:
        - podSelector: {}
  egress:
    # Allow DNS
    - ports:
        - port: 53
          protocol: UDP
    # Allow Fleet agent outbound to management cluster
    - to:
        - ipBlock:
            cidr: 172.28.0.0/16   # Docker network (management LB lives here)
      ports:
        - port: 6443
          protocol: TCP
    # Allow OCI image pulls
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
      ports:
        - port: 443
          protocol: TCP
EOF

# Repeat on edge-pro
kubectl config use-context k3d-edge-pro
kubectl apply -f - << 'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-cross-cluster
  namespace: default
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector: {}
  egress:
    - ports:
        - port: 53
          protocol: UDP
    - to:
        - ipBlock:
            cidr: 172.28.0.0/16
      ports:
        - port: 6443
          protocol: TCP
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
      ports:
        - port: 443
          protocol: TCP
EOF

kubectl config use-context k3d-mgmt
```

---

## 16. Certificate Deep Dive

### How k3s manages certificates

k3s auto-generates a self-signed CA and signs all component certificates at
first boot. Files live inside the k3s data directory (mounted into the k3d
container at `/var/lib/rancher/k3s/server/tls/`).

| File | Purpose |
|------|---------|
| `server-ca.crt` / `server-ca.key` | Root CA for API server & kubelet certs |
| `client-ca.crt` / `client-ca.key` | Client cert CA (kubectl, controller) |
| `etcd/` | etcd peer and client certs |
| `serving-kube-apiserver.crt` | API server TLS cert (SANs matter!) |

### SAN requirements for this lab

For Fleet agents in edge clusters to connect to the management API **by
container hostname** without disabling TLS verification, the management API
server cert must include `k3d-mgmt-serverlb` as a DNS SAN. We added:

```
--tls-san=k3d-mgmt-serverlb
```

in `mgmt-cluster.yaml`. This causes k3s to include that DNS name in the API
server cert. Fleet reads `apiServerCA` from the Helm value, builds a TLS config
with it, and verifies the cert against that CA — full chain validation, no
`--insecure`.

### Certificate rotation

k3s automatically rotates certificates before they expire (default lifetime
is 1 year). To manually force rotation:

```bash
# SSH into the k3d node
docker exec -it k3d-mgmt-server-0 sh
# Inside:
k3s certificate rotate
# Then restart the node (k3d handles process restart automatically)
```

After rotation, re-export `apiServerCA` and upgrade the fleet-agent Helm
release on edge clusters if the CA changed:

```bash
NEW_CA=$(kubectl config view --context k3d-mgmt --minify --raw \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

kubectl config use-context k3d-edge-pre
helm upgrade fleet-agent fleet/fleet-agent \
  -n cattle-fleet-system \
  --reuse-values \
  --set apiServerCA="$NEW_CA"

kubectl config use-context k3d-edge-pro
helm upgrade fleet-agent fleet/fleet-agent \
  -n cattle-fleet-system \
  --reuse-values \
  --set apiServerCA="$NEW_CA"
```

---

## 17. Troubleshooting

### Fleet agent stuck in `Pending` or `WaitCheckIn`

```bash
# Check agent logs
kubectl config use-context k3d-edge-pre
kubectl logs -n cattle-fleet-system \
  -l app=fleet-agent --tail=50

# Common cause: cannot reach management API
# Test from inside edge cluster:
kubectl run net-test \
  --image=nicolaka/netshoot \
  --restart=Never --rm -it \
  -- curl -v https://k3d-mgmt-serverlb:6443/healthz

# If DNS fails: check Docker network
docker network inspect k3s-iot | jq '.[0].Containers | to_entries[] | .value.Name'
```

### k3d cluster fails to start — port already in use

```bash
# Find what uses 6443
lsof -i :6443
# Change host port in cluster YAML (e.g., 16443) and recreate
```

### Fleet GitRepo shows `Error` state

```bash
kubectl describe gitrepo iiot-apps -n fleet-default
# Look for: "authentication required" → add git-credentials secret
# Look for: "x509: certificate" → CA mismatch, check apiServerCA value
```

### etcd performance warning in k3d

k3d runs k3s in Docker containers. etcd uses disk I/O heavily. On slow
laptops you may see `took too long` warnings. This is cosmetic for a lab.
For production-like behaviour, pin an SSD bind mount:

```bash
# In cluster YAML:
volumes:
  - volume: /tmp/k3s-mgmt-etcd:/var/lib/rancher/k3s/server/db
    nodeFilters: ["server:*"]
```

### Inspect actual Docker network IPs

```bash
docker network inspect k3s-iot \
  | jq '.[0].Containers | to_entries[] | {name: .value.Name, ip: .value.IPv4Address}'
```

---

## 18. Teardown

Remove all clusters and the shared network cleanly:

```bash
# Delete clusters (order doesn't matter)
k3d cluster delete mgmt
k3d cluster delete edge-pre
k3d cluster delete edge-pro

# Remove shared network
docker network rm k3s-iot

# Clean up kubeconfig contexts
kubectl config delete-context k3d-mgmt
kubectl config delete-context k3d-edge-pre
kubectl config delete-context k3d-edge-pro

# Optionally remove kubeconfig clusters/users
kubectl config delete-cluster k3d-mgmt
kubectl config delete-cluster k3d-edge-pre
kubectl config delete-cluster k3d-edge-pro
```

Verify nothing is left:

```bash
k3d cluster list          # empty
docker network ls | grep k3s-iot  # no output
kubectl config get-contexts | grep k3d  # no output
```

---

## Quick Reference Card

```
┌────────────────────────────────────────────────────────────┐
│  CONTEXT SWITCHING                                         │
│  kubectl config use-context k3d-mgmt                      │
│  kubectl config use-context k3d-edge-pre                  │
│  kubectl config use-context k3d-edge-pro                  │
├────────────────────────────────────────────────────────────┤
│  FLEET STATUS (run on mgmt)                                │
│  kubectl get gitrepo -n fleet-default                      │
│  kubectl get bundles -n fleet-default                      │
│  kubectl get clusters.fleet.cattle.io -n fleet-default    │
├────────────────────────────────────────────────────────────┤
│  CLUSTER API PORTS (host)                                  │
│  mgmt     → localhost:6443                                 │
│  edge-pre → localhost:6444                                 │
│  edge-pro → localhost:6445                                 │
├────────────────────────────────────────────────────────────┤
│  CLUSTER API PORTS (Docker network — inter-container)      │
│  mgmt     → k3d-mgmt-serverlb:6443                        │
│  edge-pre → k3d-edge-pre-serverlb:6443                    │
│  edge-pro → k3d-edge-pro-serverlb:6443                    │
├────────────────────────────────────────────────────────────┤
│  IIoT PROTOCOLS                                            │
│  MQTT plain  → edge cluster :1883 (L1 devices)            │
│  MQTT TLS    → edge cluster :8883 (preferred)             │
│  OPC-UA      → edge cluster :4840 / :4843 (TLS)          │
└────────────────────────────────────────────────────────────┘
```

---

*Generated for TMB IIoT/OT platform exploration — Rancher Desktop + k3d + Fleet*
*k3s v1.29.4 | Fleet v0.9 | Helm 3.14 | Kubernetes 1.29*
