#!/usr/bin/env bash
# Takes a fresh Ubuntu 24.04 VM to a running minikube cluster with a self-managing
# Argo CD, which then deploys everything else from this repo.
#
# Runs as root
#   - Via tofu: passed to the VM as a startup script (runs on first boot).
#   - By hand:  ssh root@<ip> 'bash -s' < bootstrap.sh

set -euxo pipefail
exec > >(tee -a /var/log/bootstrap.log) 2>&1

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
MK_USER=kube

# Pinned versions
K8S_VERSION=v1.37.0
MINIKUBE_VERSION=v1.39.0
K9S_VERSION=v0.51.0

# Base packages + Docker
apt-get update
apt-get install -y ca-certificates curl conntrack docker.io
systemctl enable --now docker

# kubectl
curl -fsSLo /usr/local/bin/kubectl \
  "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubectl"
chmod +x /usr/local/bin/kubectl

# minikube
curl -fsSLo /usr/local/bin/minikube \
  "https://storage.googleapis.com/minikube/releases/${MINIKUBE_VERSION}/minikube-linux-amd64"
chmod +x /usr/local/bin/minikube

# k9s
curl -fsSL "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_amd64.tar.gz" \
  | tar -xz -C /usr/local/bin k9s

# Non-root user for the docker driver
id "$MK_USER" &>/dev/null || useradd -m -s /bin/bash "$MK_USER"
usermod -aG docker "$MK_USER"

# Start the cluster
sudo -iu "$MK_USER" minikube start --driver=docker --kubernetes-version="$K8S_VERSION" --cpus=3 --memory=12g

# Bootstrap self-managing Argo CD
sudo -iu "$MK_USER" bash -euxo pipefail <<'INNER'
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
# Retry: the first pass can fail on the Application/ApplicationSet until their CRDs are registered
for i in $(seq 1 5); do
  kubectl apply -k "https://github.com/waleksi/verda-cloud-obs-demo//argocd?ref=main" --server-side --force-conflicts && break
  [ "$i" -eq 5 ] && exit 1
  sleep 10
done
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s
INNER
