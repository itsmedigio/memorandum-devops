# Vault + Kubernetes Auth — Java Demo

This project demonstrates how to authenticate a Java application running in Kubernetes with HashiCorp Vault using the Kubernetes Auth Method.

## Prerequisites

* [Minikube](https://minikube.sigs.k8s.io/docs/start/) installed and running.
* [Podman](https://podman.io/) or Docker installed.
* [kubectl](https://kubernetes.io/docs/tasks/tools/) configured to point to your Minikube cluster.
* A running HashiCorp Vault instance (accessible from the cluster).

## 1. Build and Load Image

Build the Java application container image and load it into Minikube.

```bash
# Build the image using Podman
podman build -t vault-demo:latest .

# Export to tarball (optional intermediate step)
podman save vault-demo:latest -o vault-demo.tar

# Load the image into Minikube
minikube image load vault-demo.tar

# Verify the image is available in Minikube
minikube image ls | grep vault-demo
```

> **Note:** If you are using Docker instead of Podman, replace `podman` with `docker` in the commands above. Alternatively, you can use `eval $(minikube docker-env)` and build directly into the Minikube Docker daemon.

## 2. Deploy & Access Headlamp Dashboard (Optional)

If you wish to view the cluster state via the Headlamp dashboard, use the following commands.

```bash
# Get the Headlamp pod name
POD_NAME=$(kubectl get pods --namespace kube-system \
  -l "app.kubernetes.io/name=headlamp,app.kubernetes.io/instance=my-headlamp" \
  -o jsonpath="{.items[0].metadata.name}")

# Get the container port
CONTAINER_PORT=$(kubectl get pod --namespace kube-system $POD_NAME \
  -o jsonpath="{.spec.containers[0].ports[0].containerPort}")

# Port-forward to local machine
echo "Visit http://127.0.0.1:8080 to use your application"
kubectl --namespace kube-system port-forward $POD_NAME 8080:$CONTAINER_PORT
```

### Authentication Token for Dashboard

To log in to the dashboard, generate a service account token:

```bash
kubectl create token my-headlamp -n kube-system
```

## 3. Deploy the Vault Demo Application

*(Add specific deployment commands here, e.g., kubectl apply -f k8s/deployment.yaml)*

```bash
kubectl apply -f deployment.yaml
```

## Architecture

The following diagram illustrates the authentication flow between the Java application, Kubernetes, and Vault.

```text
┌──────────────────────────────────────────────────────────────┐
│  Kubernetes Cluster                                          │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐  │
│  │  Pod: vault-demo                                       │  │
│  │                                                        │  │
│  │  ┌──────────────┐      ┌──────────────────────────┐   │  │
│  │  │  Java App    │─────▶│  Vault Agent / Sidecar   │   │  │
│  │  │              │      │  (or direct SDK call)    │   │  │
│  │  └──────────────┘      └──────────┬───────────────┘   │  │
│  │                                   │                   │  │
│  │                                   │ 1. Auth Request   │  │
│  │                                   │ (JWT Token)       │  │
│  └───────────────────────────────────┼───────────────────┘  │
│                                      │                      │
│  ┌───────────────────────────────────┼──────────────────┐  │
│  │  K8s API Server                  │                  │  │
│  │                                  │ 2. TokenReview    │  │
│  └──────────────────────────────────┼──────────────────┘  │
│                                     │                    │
└─────────────────────────────────────┼────────────────────┘
                                      │
┌─────────────────────────────────────┼────────────────────┐
│  HashiCorp Vault                   │                    │
│                                    │                    │
│  ┌─────────────────────────────────▼──────────────────┐ │
│  │  Kubernetes Auth Backend                           │ │
│  │                                                    │ │
│  │  3. Verify JWT with K8s API                        │ │
│  │  4. Return Vault Token & Secrets                   │ │
│  └────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────┘
```

### Flow Explanation

1. The **Java App** retrieves its Service Account JWT token from `/var/run/secrets/kubernetes.io/serviceaccount/token`.
2. It sends this JWT to **Vault**'s Kubernetes auth endpoint.
3. **Vault** uses the Kubernetes TokenReview API to verify the JWT's validity and signature.
4. Upon successful verification, Vault returns a **Vault Token** and any associated secrets (e.g., database credentials) to the application.
