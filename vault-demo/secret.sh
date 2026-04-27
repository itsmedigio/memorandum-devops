#!/bin/bash

# Run this once against your Vault instance (from inside the cluster or
# after `kubectl port-forward svc/vault 8200:8200`).
#
# Prerequisites:
#   brew install vault
#   (source .env if you have one with VAULT_ADDR/VAULT_TOKEN)
#   - VAULT_ADDR and VAULT_TOKEN (root/admin) are set in your shell
#   - kubectl is configured to point at your local cluster
#   - Vault is already running in Kubernetes

set -euo pipefail

NAMESPACE="default"           # namespace where your app will run
SA_NAME="vault-demo-sa"       # ServiceAccount for the app pod
VAULT_ROLE="vault-demo-role"  # Vault Kubernetes auth role
POLICY_NAME="vault-demo-policy"
SECRET_PATH="kv/data/db_password"  # must match your existing secret path

echo "=== 1. Write sample secret ==="
vault kv put kv/db_password password="SuperSecret01!"
echo "Secret written."

echo ""
echo "=== 2. Create Vault policy ==="
vault policy write "$POLICY_NAME" - <<EOF
path "kv/data/db_password" {
  capabilities = ["read"]
}
EOF
echo "Policy '$POLICY_NAME' created."

echo ""
echo "=== 3. Enable Kubernetes auth (skip if already enabled) ==="
vault auth enable kubernetes 2>/dev/null || echo "Kubernetes auth already enabled."

echo ""
echo "=== 4. Configure Kubernetes auth backend ==="
# Retrieve the K8s API server address and the cluster's CA cert
K8S_HOST="https://kubernetes.default.svc"
K8S_CA=$(kubectl config view --raw --minify --flatten \
  -o jsonpath='{.clusters[].cluster.certificate-authority-data}' | base64 --decode)

# Get a token for the vault service account (used by Vault to validate pod tokens)
# For Kubernetes 1.24+ we create a short-lived token on the fly
K8S_TOKEN=$(kubectl create token vault -n default 2>/dev/null \
  || kubectl get secret -n default \
       $(kubectl get sa vault -n default -o jsonpath='{.secrets[0].name}') \
       -o jsonpath='{.data.token}' | base64 --decode)

vault write auth/kubernetes/config \
  kubernetes_host="$K8S_HOST" \
  kubernetes_ca_cert="$K8S_CA" \
  token_reviewer_jwt="$K8S_TOKEN"

echo "Kubernetes auth backend configured."

echo ""
echo "=== 5. Create Kubernetes auth role ==="
vault write "auth/kubernetes/role/$VAULT_ROLE" \
  bound_service_account_names="$SA_NAME" \
  bound_service_account_namespaces="$NAMESPACE" \
  policies="$POLICY_NAME" \
  ttl="1h"
echo "Role '$VAULT_ROLE' created."

echo ""
echo "=== Done! ==="
echo "Vault is configured. You can now deploy the app with:"
echo "  kubectl apply -f k8s/"