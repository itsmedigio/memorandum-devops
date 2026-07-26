#!/bin/bash
set -euxo pipefail

# Disabilita swap
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# Carica moduli kernel
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

# Sysctl per Kubernetes
cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system > /dev/null 2>&1

# Hostname e IP
echo "$NODE_IP $NODE_NAME" >> /etc/hosts

# Hosts file - tutti i nodi (per risoluzione nomi)
cat >> /etc/hosts <<EOF
192.168.56.11 cp-1
192.168.56.21 worker-1
192.168.56.22 worker-2
EOF

# Pacchetti di base
apt-get update -qq
apt-get install -y -qq \
  apt-transport-https \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  jq \
  socat \
  netcat-openbsd \
  vim \
  tar \
  gzip

echo "✅ $NODE_NAME pronto."
