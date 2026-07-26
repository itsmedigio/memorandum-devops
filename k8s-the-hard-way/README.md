# K8s the Hard Way

## Kubernetes da zero — manuale, senza automagic

Tutorial basato sull'originale di **Kelsey Hightower**, adattato per ambiente locale con **Vagrant + VirtualBox** su 1 control-plane e 2 worker node.

### Obiettivo

Costruire un cluster Kubernetes **manualmente** passo dopo passo:

- Certificati TLS con `cfssl`
- Cluster etcd singolo nodo
- Control Plane (kube-apiserver, kube-controller-manager, kube-scheduler) come **systemd services**
- Worker Nodes con containerd, kubelet, kube-proxy
- Networking con Flannel
- CoreDNS
- Smoke test finale

### Versione Kubernetes

```
KUBERNETES_VERSION=1.31.2
ETCD_VERSION=3.5.15
CONTAINERD_VERSION=1.7.22
RUNC_VERSION=1.2.0
CNI_PLUGINS_VERSION=1.5.1
```

### Architettura

```
        Internet
            |
    [192.168.56.0/24]
       |         |
   cp-1         worker-1       worker-2
   .11          .21            .22
   ┌──────┐    ┌────────┐    ┌────────┐
   │ etcd │    │ kubelet│    │ kubelet│
   │ api  │    │ kube-pr│    │ kube-pr│
   │ kmgr │    │ contain│    │ contain│
   │ ksch │    │ flannel│    │ flannel│
   └──────┘    └────────┘    └────────┘
```

**Pod CIDR:** `10.200.0.0/16` — Worker-1: `10.200.0.0/24`, Worker-2: `10.200.1.0/24`
**Service CIDR:** `10.96.0.0/24` — DNS: `10.96.0.10`

---

## 0. Provisioning VM

Dalla tua macchina:

```bash
cd k8s-the-hard-way
vagrant up
```

Attendi che tutte e 3 le VM siano pronte (2-5 minuti). Verifica:

```bash
vagrant status
vagrant ssh cp-1
```

Il provisioning Vagrant ha già:

- Disabilitato swap
- Caricato moduli kernel (`overlay`, `br_netfilter`)
- Impostato sysctl (`net.ipv4.ip_forward = 1`)
- Installato strumenti di base (curl, jq, socat, etc.)
- Aggiunto `/etc/hosts` su tutti i nodi

Da qui in avanti lavorerai principalmente su **cp-1** (dove genererai certificati e config), poi copierai i file su worker-1 e worker-2.

---

## 1. Strumenti su cp-1

SSH su cp-1 e imposta le variabili d'ambiente:

```bash
vagrant ssh cp-1
```

```bash
KUBERNETES_VERSION=1.31.2
ETCD_VERSION=3.5.15
CONTAINERD_VERSION=1.7.22
RUNC_VERSION=1.2.0
CNI_PLUGINS_VERSION=1.5.1
```

```bash
mkdir -p /tmp/k8s && cd /tmp/k8s
```

### cfssl

```bash
wget -q --show-progress --https-only --timestamping \
  "https://github.com/cloudflare/cfssl/releases/download/v1.6.5/cfssl_1.6.5_linux_amd64" \
  "https://github.com/cloudflare/cfssl/releases/download/v1.6.5/cfssljson_1.6.5_linux_amd64"

chmod +x cfssl_1.6.5_linux_amd64 cfssljson_1.6.5_linux_amd64
sudo mv cfssl_1.6.5_linux_amd64 /usr/local/bin/cfssl
sudo mv cfssljson_1.6.5_linux_amd64 /usr/local/bin/cfssljson
```

### kubectl

```bash
wget -q "https://dl.k8s.io/release/v${KUBERNETES_VERSION}/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/
```

Verifica:

```bash
cfssl version
kubectl version --client
```

---

## 2. Certificati TLS

Tutti i certificati si generano su **cp-1** in una directory dedicata:

```bash
mkdir -p /tmp/k8s/certs && cd /tmp/k8s/certs
```

### 2.1 CA

```bash
cat > ca-config.json << 'EOF'
{
  "signing": {
    "default": {
      "expiry": "8760h"
    },
    "profiles": {
      "kubernetes": {
        "usages": ["signing", "key encipherment", "server auth", "client auth"],
        "expiry": "8760h"
      }
    }
  }
}
EOF

cat > ca-csr.json << 'EOF'
{
  "CN": "Kubernetes",
  "key": { "algo": "rsa", "size": 2048 },
  "names": [
    { "C": "IT", "L": "Milano", "O": "Kubernetes", "OU": "CA" }
  ]
}
EOF

cfssl gencert -initca ca-csr.json | cfssljson -bare ca
```

### 2.2 Admin client

```bash
cat > admin-csr.json << 'EOF'
{
  "CN": "admin",
  "key": { "algo": "rsa", "size": 2048 },
  "names": [
    { "C": "IT", "L": "Milano", "O": "system:masters", "OU": "K8s The Hard Way" }
  ]
}
EOF

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=kubernetes \
  admin-csr.json | cfssljson -bare admin
```

### 2.3 Kubelet (worker-1 e worker-2)

```bash
for instance in worker-1 worker-2; do
  cat > ${instance}-csr.json << EOF
{
  "CN": "system:node:${instance}",
  "key": { "algo": "rsa", "size": 2048 },
  "names": [
    { "C": "IT", "L": "Milano", "O": "system:nodes", "OU": "K8s The Hard Way" }
  ]
}
EOF

  IP=$(getent hosts ${instance} | awk '{print $1}')

  cfssl gencert \
    -ca=ca.pem \
    -ca-key=ca-key.pem \
    -config=ca-config.json \
    -hostname=${instance},${IP} \
    -profile=kubernetes \
    ${instance}-csr.json | cfssljson -bare ${instance}
done
```

### 2.4 kube-controller-manager

```bash
cat > kube-controller-manager-csr.json << 'EOF'
{
  "CN": "system:kube-controller-manager",
  "key": { "algo": "rsa", "size": 2048 },
  "names": [
    { "C": "IT", "L": "Milano", "O": "system:kube-controller-manager", "OU": "K8s The Hard Way" }
  ]
}
EOF

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=kubernetes \
  kube-controller-manager-csr.json | cfssljson -bare kube-controller-manager
```

### 2.5 kube-scheduler

```bash
cat > kube-scheduler-csr.json << 'EOF'
{
  "CN": "system:kube-scheduler",
  "key": { "algo": "rsa", "size": 2048 },
  "names": [
    { "C": "IT", "L": "Milano", "O": "system:kube-scheduler", "OU": "K8s The Hard Way" }
  ]
}
EOF

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=kubernetes \
  kube-scheduler-csr.json | cfssljson -bare kube-scheduler
```

### 2.6 kube-proxy

```bash
cat > kube-proxy-csr.json << 'EOF'
{
  "CN": "system:kube-proxy",
  "key": { "algo": "rsa", "size": 2048 },
  "names": [
    { "C": "IT", "L": "Milano", "O": "system:node-proxier", "OU": "K8s The Hard Way" }
  ]
}
EOF

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=kubernetes \
  kube-proxy-csr.json | cfssljson -bare kube-proxy
```

### 2.7 API Server

Il certificato del server API deve includere **tutti i nomi e IP** con cui sarà contattato:

```bash
cat > kubernetes-csr.json << 'EOF'
{
  "CN": "kubernetes",
  "key": { "algo": "rsa", "size": 2048 },
  "names": [
    { "C": "IT", "L": "Milano", "O": "Kubernetes", "OU": "K8s The Hard Way" }
  ]
}
EOF

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -hostname=10.96.0.1,192.168.56.11,127.0.0.1,kubernetes,kubernetes.default,kubernetes.default.svc \
  -profile=kubernetes \
  kubernetes-csr.json | cfssljson -bare kubernetes
```

### 2.8 Service Account

```bash
cat > service-account-csr.json << 'EOF'
{
  "CN": "service-accounts",
  "key": { "algo": "rsa", "size": 2048 },
  "names": [
    { "C": "IT", "L": "Milano", "O": "Kubernetes", "OU": "K8s The Hard Way" }
  ]
}
EOF

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=kubernetes \
  service-account-csr.json | cfssljson -bare service-account
```

Verifica che tutti i file siano presenti:

```bash
ls -la *.pem
```

---

## 3. Kubeconfig

Sempre su cp-1, crea i kubeconfig per ogni componente.

```bash
cd /tmp/k8s/certs

KUBERNETES_PUBLIC_ADDRESS=192.168.56.11
```

### 3.1 Kubelet (worker-1, worker-2)

```bash
for instance in worker-1 worker-2; do
  kubectl config set-cluster k8s-the-hard-way \
    --certificate-authority=ca.pem \
    --embed-certs=true \
    --server=https://${KUBERNETES_PUBLIC_ADDRESS}:6443 \
    --kubeconfig=${instance}.kubeconfig

  kubectl config set-credentials system:node:${instance} \
    --client-certificate=${instance}.pem \
    --client-key=${instance}-key.pem \
    --embed-certs=true \
    --kubeconfig=${instance}.kubeconfig

  kubectl config set-context default \
    --cluster=k8s-the-hard-way \
    --user=system:node:${instance} \
    --kubeconfig=${instance}.kubeconfig

  kubectl config use-context default --kubeconfig=${instance}.kubeconfig
done
```

### 3.2 kube-proxy

```bash
kubectl config set-cluster k8s-the-hard-way \
  --certificate-authority=ca.pem \
  --embed-certs=true \
  --server=https://${KUBERNETES_PUBLIC_ADDRESS}:6443 \
  --kubeconfig=kube-proxy.kubeconfig

kubectl config set-credentials system:kube-proxy \
  --client-certificate=kube-proxy.pem \
  --client-key=kube-proxy-key.pem \
  --embed-certs=true \
  --kubeconfig=kube-proxy.kubeconfig

kubectl config set-context default \
  --cluster=k8s-the-hard-way \
  --user=system:kube-proxy \
  --kubeconfig=kube-proxy.kubeconfig

kubectl config use-context default --kubeconfig=kube-proxy.kubeconfig
```

### 3.3 kube-controller-manager

```bash
kubectl config set-cluster k8s-the-hard-way \
  --certificate-authority=ca.pem \
  --embed-certs=true \
  --server=https://127.0.0.1:6443 \
  --kubeconfig=kube-controller-manager.kubeconfig

kubectl config set-credentials system:kube-controller-manager \
  --client-certificate=kube-controller-manager.pem \
  --client-key=kube-controller-manager-key.pem \
  --embed-certs=true \
  --kubeconfig=kube-controller-manager.kubeconfig

kubectl config set-context default \
  --cluster=k8s-the-hard-way \
  --user=system:kube-controller-manager \
  --kubeconfig=kube-controller-manager.kubeconfig

kubectl config use-context default --kubeconfig=kube-controller-manager.kubeconfig
```

### 3.4 kube-scheduler

```bash
kubectl config set-cluster k8s-the-hard-way \
  --certificate-authority=ca.pem \
  --embed-certs=true \
  --server=https://127.0.0.1:6443 \
  --kubeconfig=kube-scheduler.kubeconfig

kubectl config set-credentials system:kube-scheduler \
  --client-certificate=kube-scheduler.pem \
  --client-key=kube-scheduler-key.pem \
  --embed-certs=true \
  --kubeconfig=kube-scheduler.kubeconfig

kubectl config set-context default \
  --cluster=k8s-the-hard-way \
  --user=system:kube-scheduler \
  --kubeconfig=kube-scheduler.kubeconfig

kubectl config use-context default --kubeconfig=kube-scheduler.kubeconfig
```

### 3.5 Admin user (per il tuo kubectl locale)

```bash
kubectl config set-cluster k8s-the-hard-way \
  --certificate-authority=ca.pem \
  --embed-certs=true \
  --server=https://127.0.0.1:6443 \
  --kubeconfig=admin.kubeconfig

kubectl config set-credentials admin \
  --client-certificate=admin.pem \
  --client-key=admin-key.pem \
  --embed-certs=true \
  --kubeconfig=admin.kubeconfig

kubectl config set-context default \
  --cluster=k8s-the-hard-way \
  --user=admin \
  --kubeconfig=admin.kubeconfig

kubectl config use-context default --kubeconfig=admin.kubeconfig
```

---

## 4. Copia certificati e kubeconfig sui nodi

Da **cp-1**, copia i file sui worker:

```bash
cd /tmp/k8s/certs

for instance in worker-1 worker-2; do
  scp -o StrictHostKeyChecking=no \
    ca.pem ${instance}-key.pem ${instance}.pem \
    ${instance}.kubeconfig kube-proxy.kubeconfig \
    ${instance}:~/
done
```

Crea la directory di lavoro anche su cp-1:

```bash
sudo mkdir -p /var/lib/kubernetes
sudo cp ca.pem ca-key.pem kubernetes-key.pem kubernetes.pem \
  service-account-key.pem service-account.pem \
  admin.kubeconfig kube-controller-manager.kubeconfig kube-scheduler.kubeconfig \
  /var/lib/kubernetes/
```

---

## 5. Etcd

Sempre su **cp-1**:

```bash
cd /tmp/k8s

ETCD_VERSION=3.5.15

wget -q --show-progress --https-only --timestamping \
  "https://github.com/etcd-io/etcd/releases/download/v${ETCD_VERSION}/etcd-v${ETCD_VERSION}-linux-amd64.tar.gz"

tar -xvf etcd-v${ETCD_VERSION}-linux-amd64.tar.gz
sudo mv etcd-v${ETCD_VERSION}-linux-amd64/etcd* /usr/local/bin/
```

Crea utente e directory:

```bash
sudo mkdir -p /etc/etcd /var/lib/etcd
sudo groupadd --system etcd || true
sudo useradd -s /sbin/nologin --system -g etcd etcd || true
sudo chown -R etcd:etcd /var/lib/etcd
```

Crea il file di configurazione:

```bash
cat <<EOF | sudo tee /etc/etcd/etcd.conf.yml
name: cp-1
data-dir: /var/lib/etcd
listen-client-urls: https://192.168.56.11:2379,https://127.0.0.1:2379
advertise-client-urls: https://192.168.56.11:2379
listen-peer-urls: https://192.168.56.11:2380
initial-advertise-peer-urls: https://192.168.56.11:2380
initial-cluster: cp-1=https://192.168.56.11:2380
initial-cluster-token: etcd-cluster-0
initial-cluster-state: new
client-transport-security:
  cert-file: /var/lib/kubernetes/kubernetes.pem
  key-file: /var/lib/kubernetes/kubernetes-key.pem
  client-cert-auth: true
  trusted-ca-file: /var/lib/kubernetes/ca.pem
peer-transport-security:
  cert-file: /var/lib/kubernetes/kubernetes.pem
  key-file: /var/lib/kubernetes/kubernetes-key.pem
  client-cert-auth: true
  trusted-ca-file: /var/lib/kubernetes/ca.pem
EOF
```

Crea il systemd service:

```bash
cat <<EOF | sudo tee /etc/systemd/system/etcd.service
[Unit]
Description=etcd
Documentation=https://github.com/etcd-io/etcd

[Service]
Type=notify
User=etcd
Group=etcd
ExecStart=/usr/local/bin/etcd --config-file=/etc/etcd/etcd.conf.yml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
```

Avvia etcd:

```bash
sudo systemctl daemon-reload
sudo systemctl enable etcd
sudo systemctl start etcd
```

Verifica:

```bash
sudo etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/var/lib/kubernetes/ca.pem \
  --cert=/var/lib/kubernetes/kubernetes.pem \
  --key=/var/lib/kubernetes/kubernetes-key.pem \
  endpoint health
```

Output atteso: `https://127.0.0.1:2379 is healthy`

---

## 6. Control Plane

Sempre su **cp-1**:

### 6.1 Scarica i binari

```bash
cd /tmp/k8s

wget -q --show-progress --https-only --timestamping \
  "https://dl.k8s.io/release/v${KUBERNETES_VERSION}/bin/linux/amd64/kube-apiserver" \
  "https://dl.k8s.io/release/v${KUBERNETES_VERSION}/bin/linux/amd64/kube-controller-manager" \
  "https://dl.k8s.io/release/v${KUBERNETES_VERSION}/bin/linux/amd64/kube-scheduler" \
  "https://dl.k8s.io/release/v${KUBERNETES_VERSION}/bin/linux/amd64/kubectl"

chmod +x kube-apiserver kube-controller-manager kube-scheduler kubectl
sudo mv kube-apiserver kube-controller-manager kube-scheduler kubectl /usr/local/bin/
```

### 6.2 kube-apiserver

```bash
sudo mkdir -p /etc/kubernetes/config
```

```bash
cat <<EOF | sudo tee /etc/kubernetes/kube-apiserver.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
- name: NodeRestriction
EOF
```

```bash
cat <<EOF | sudo tee /etc/systemd/system/kube-apiserver.service
[Unit]
Description=Kubernetes API Server
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-apiserver \\
  --advertise-address=192.168.56.11 \\
  --allow-privileged=true \\
  --authorization-mode=Node,RBAC \\
  --client-ca-file=/var/lib/kubernetes/ca.pem \\
  --enable-admission-plugins=NodeRestriction \\
  --enable-bootstrap-token-auth=true \\
  --etcd-cafile=/var/lib/kubernetes/ca.pem \\
  --etcd-certfile=/var/lib/kubernetes/kubernetes.pem \\
  --etcd-keyfile=/var/lib/kubernetes/kubernetes-key.pem \\
  --etcd-servers=https://192.168.56.11:2379 \\
  --kubelet-client-certificate=/var/lib/kubernetes/kubernetes.pem \\
  --kubelet-client-key=/var/lib/kubernetes/kubernetes-key.pem \\
  --kubelet-preferred-address-types=InternalIP,InternalDNS,Hostname,ExternalIP,ExternalDNS \\
  --proxy-client-cert-file=/var/lib/kubernetes/kubernetes.pem \\
  --proxy-client-key-file=/var/lib/kubernetes/kubernetes-key.pem \\
  --requestheader-allowed-names= \\
  --requestheader-client-ca-file=/var/lib/kubernetes/ca.pem \\
  --requestheader-extra-headers-prefix=X-Remote-Extra- \\
  --requestheader-group-headers=X-Remote-Group \\
  --requestheader-username-headers=X-Remote-User \\
  --secure-port=6443 \\
  --service-account-issuer=https://kubernetes.default.svc.cluster.local \\
  --service-account-key-file=/var/lib/kubernetes/service-account.pem \\
  --service-account-signing-key-file=/var/lib/kubernetes/service-account-key.pem \\
  --service-cluster-ip-range=10.96.0.0/24 \\
  --service-node-port-range=30000-32767 \\
  --tls-cert-file=/var/lib/kubernetes/kubernetes.pem \\
  --tls-private-key-file=/var/lib/kubernetes/kubernetes-key.pem \\
  --v=2
Restart=always
RestartSec=5
Type=notify
User=nobody

[Install]
WantedBy=multi-user.target
EOF
```

### 6.3 kube-controller-manager

```bash
cat <<EOF | sudo tee /etc/systemd/system/kube-controller-manager.service
[Unit]
Description=Kubernetes Controller Manager
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-controller-manager \\
  --allocate-node-cidrs=true \\
  --bind-address=0.0.0.0 \\
  --cluster-cidr=10.200.0.0/16 \\
  --cluster-name=k8s-the-hard-way \\
  --cluster-signing-cert-file=/var/lib/kubernetes/ca.pem \\
  --cluster-signing-key-file=/var/lib/kubernetes/ca-key.pem \\
  --kubeconfig=/var/lib/kubernetes/kube-controller-manager.kubeconfig \\
  --leader-elect=true \\
  --node-cidr-mask-size-ipv4=24 \\
  --root-ca-file=/var/lib/kubernetes/ca.pem \\
  --service-account-private-key-file=/var/lib/kubernetes/service-account-key.pem \\
  --service-cluster-ip-range=10.96.0.0/24 \\
  --use-service-account-credentials=true \\
  --v=2
Restart=always
RestartSec=5
User=nobody

[Install]
WantedBy=multi-user.target
EOF
```

### 6.4 kube-scheduler

```bash
cat <<EOF | sudo tee /etc/systemd/system/kube-scheduler.service
[Unit]
Description=Kubernetes Scheduler
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-scheduler \\
  --kubeconfig=/var/lib/kubernetes/kube-scheduler.kubeconfig \\
  --leader-elect=true \\
  --v=2
Restart=always
RestartSec=5
User=nobody

[Install]
WantedBy=multi-user.target
EOF
```

### 6.5 Avvia tutto

```bash
sudo systemctl daemon-reload
sudo systemctl enable kube-apiserver kube-controller-manager kube-scheduler
sudo systemctl start kube-apiserver kube-controller-manager kube-scheduler
```

### 6.6 Verifica

```bash
kubectl get componentstatuses --kubeconfig /var/lib/kubernetes/admin.kubeconfig
```

In alternativa (più affidabile su K8s 1.31):

```bash
kubectl get pods -n kube-system --kubeconfig /var/lib/kubernetes/admin.kubeconfig

curl --cacert /var/lib/kubernetes/ca.pem --cert /var/lib/kubernetes/admin.pem \
  --key /var/lib/kubernetes/admin-key.pem \
  https://127.0.0.1:6443/healthz
```

Output atteso: `ok`

---

## 7. Worker Nodes

Ogni comando in questa sezione va eseguito **sia su worker-1 che su worker-2**.

Apri due terminali separati:

```bash
# Terminale 1
vagrant ssh worker-1

# Terminale 2
vagrant ssh worker-2
```

### 7.1 containerd

```bash
CONTAINERD_VERSION=1.7.22
RUNC_VERSION=1.2.0
CNI_PLUGINS_VERSION=1.5.1
```

```bash
cd /tmp
```

#### runc

```bash
wget -q --show-progress --https-only --timestamping \
  "https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.amd64"

sudo install -m 755 runc.amd64 /usr/local/sbin/runc
```

#### containerd

```bash
wget -q --show-progress --https-only --timestamping \
  "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz"

sudo tar -C /usr/local -xzf containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz

sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml

# Imposta systemd cgroup driver
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
```

```bash
cat <<EOF | sudo tee /etc/systemd/system/containerd.service
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target

[Service]
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/containerd
Type=notify
Restart=always
RestartSec=5
Delegate=yes
KillMode=process
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
EOF
```

#### CNI plugins

```bash
wget -q --show-progress --https-only --timestamping \
  "https://github.com/containernetworking/plugins/releases/download/v${CNI_PLUGINS_VERSION}/cni-plugins-linux-amd64-v${CNI_PLUGINS_VERSION}.tgz"

sudo mkdir -p /opt/cni/bin
sudo tar -C /opt/cni/bin -xzf cni-plugins-linux-amd64-v${CNI_PLUGINS_VERSION}.tgz
```

Avvia containerd:

```bash
sudo systemctl daemon-reload
sudo systemctl enable containerd
sudo systemctl start containerd
```

Verifica:

```bash
sudo ctr version
```

### 7.2 kubelet + kube-proxy

Scarica i binari:

```bash
cd /tmp

wget -q --show-progress --https-only --timestamping \
  "https://dl.k8s.io/release/v${KUBERNETES_VERSION}/bin/linux/amd64/kubelet" \
  "https://dl.k8s.io/release/v${KUBERNETES_VERSION}/bin/linux/amd64/kube-proxy"

chmod +x kubelet kube-proxy
sudo mv kubelet kube-proxy /usr/local/bin/
```

### 7.3 Configura kubelet

```bash
sudo mkdir -p /var/lib/kubelet /var/lib/kubernetes /var/run/kubernetes

# Copia i file arrivati da cp-1
sudo mv ~/ca.pem ~/*.kubeconfig /var/lib/kubernetes/
sudo chown -R root:root /var/lib/kubernetes
```

Crea il file di configurazione kubelet:

```bash
cat <<EOF | sudo tee /var/lib/kubelet/kubelet-config.yaml
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
  x509:
    clientCAFile: /var/lib/kubernetes/ca.pem
authorization:
  mode: Webhook
clusterDomain: cluster.local
clusterDNS:
- 10.96.0.10
resolvConf: /etc/resolv.conf
runtimeRequestTimeout: "15m"
tlsCertFile: /var/lib/kubernetes/$(hostname).pem
tlsPrivateKeyFile: /var/lib/kubernetes/$(hostname)-key.pem
registerNode: true
cgroupDriver: systemd
containerRuntimeEndpoint: unix:///run/containerd/containerd.sock
evictionHard:
  memory.available: "200Mi"
  nodefs.available: "10%"
  nodefs.inodesFree: "5%"
EOF
```

Systemd service per kubelet:

```bash
cat <<EOF | sudo tee /etc/systemd/system/kubelet.service
[Unit]
Description=Kubernetes Kubelet
Documentation=https://github.com/kubernetes/kubernetes
After=containerd.service
Requires=containerd.service

[Service]
ExecStart=/usr/local/bin/kubelet \\
  --config=/var/lib/kubelet/kubelet-config.yaml \\
  --kubeconfig=/var/lib/kubernetes/$(hostname).kubeconfig \\
  --v=2
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
```

### 7.4 Configura kube-proxy

```bash
sudo mkdir -p /var/lib/kube-proxy
```

```bash
cat <<EOF | sudo tee /var/lib/kube-proxy/kube-proxy-config.yaml
kind: KubeProxyConfiguration
apiVersion: kubeproxy.config.k8s.io/v1alpha1
bindAddress: 0.0.0.0
clientConnection:
  kubeconfig: /var/lib/kubernetes/kube-proxy.kubeconfig
clusterCIDR: 10.200.0.0/16
hostnameOverride: $(hostname)
mode: iptables
EOF
```

```bash
cat <<EOF | sudo tee /etc/systemd/system/kube-proxy.service
[Unit]
Description=Kubernetes Kube Proxy
Documentation=https://github.com/kubernetes/kubernetes
After=network.target

[Service]
ExecStart=/usr/local/bin/kube-proxy \\
  --config=/var/lib/kube-proxy/kube-proxy-config.yaml \\
  --v=2
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
```

### 7.5 Avvia i servizi

```bash
sudo systemctl daemon-reload
sudo systemctl enable kubelet kube-proxy
sudo systemctl start kubelet kube-proxy
```

### 7.6 Verifica (da cp-1)

Torna su cp-1 e controlla che i nodi si siano registrati:

```bash
kubectl get nodes --kubeconfig /var/lib/kubernetes/admin.kubeconfig
```

Output atteso:

```
NAME        STATUS   ROLES    AGE   VERSION
worker-1    NotReady   <none>   10s   v1.31.2
worker-2    NotReady   <none>   5s    v1.31.2
```

Lo stato `NotReady` è normale: manca la CNI (networking).

---

## 8. Networking (Flannel)

Da **cp-1**:

### 8.1 RBAC per Flannel

```bash
kubectl --kubeconfig /var/lib/kubernetes/admin.kubeconfig apply -f - <<EOF
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: flannel
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: flannel
rules:
- apiGroups:
  - ""
  resources:
  - pods
  verbs:
  - get
- apiGroups:
  - ""
  resources:
  - nodes
  verbs:
  - get
  - list
  - watch
- apiGroups:
  - ""
  resources:
  - nodes/status
  verbs:
  - patch
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: flannel
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: flannel
subjects:
- kind: ServiceAccount
  name: flannel
  namespace: kube-system
EOF
```

### 8.2 ConfigMap Flannel

```bash
kubectl --kubeconfig /var/lib/kubernetes/admin.kubeconfig apply -f - <<EOF
kind: ConfigMap
apiVersion: v1
metadata:
  name: kube-flannel-cfg
  namespace: kube-system
  labels:
    tier: node
    app: flannel
data:
  cni-conf.json: |
    {
      "name": "cbr0",
      "cniVersion": "0.3.1",
      "plugins": [
        {
          "type": "flannel",
          "delegate": {
            "hairpinMode": true,
            "isDefaultGateway": true
          }
        },
        {
          "type": "portmap",
          "capabilities": {
            "portMappings": true
          }
        }
      ]
    }
  net-conf.json: |
    {
      "Network": "10.200.0.0/16",
      "Backend": {
        "Type": "vxlan"
      }
    }
EOF
```

### 8.3 DaemonSet Flannel

Il DaemonSet Flannel usa `hostNetwork: true` per bypassare la CNI (che deve ancora essere installata) e rileva automaticamente l'interfaccia di rete privata tramite regex sull'IP.

```bash
kubectl --kubeconfig /var/lib/kubernetes/admin.kubeconfig apply -f - <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: kube-flannel-ds
  namespace: kube-system
spec:
  selector:
    matchLabels:
      app: flannel
  template:
    metadata:
      labels:
        app: flannel
    spec:
      hostNetwork: true
      serviceAccountName: flannel
      tolerations:
      - operator: Exists
      containers:
      - name: kube-flannel
        image: docker.io/flannelcni/flannel:v0.25.7
        args:
        - --ip-masq
        - --kube-subnet-mgr
        - --iface-regex=192.168.56
        securityContext:
          privileged: true
        env:
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        volumeMounts:
        - name: run
          mountPath: /run
        - name: flannel-cfg
          mountPath: /etc/kube-flannel/
        - name: cni
          mountPath: /opt/cni/bin
        - name: host-cni-conf
          mountPath: /etc/cni/net.d
      volumes:
      - name: run
        hostPath:
          path: /run
      - name: flannel-cfg
        configMap:
          name: kube-flannel-cfg
      - name: cni
        hostPath:
          path: /opt/cni/bin
      - name: host-cni-conf
        hostPath:
          path: /etc/cni/net.d
EOF
```

### 8.4 Verifica networking

```bash
kubectl get nodes --kubeconfig /var/lib/kubernetes/admin.kubeconfig
```

Attendi 30-60 secondi. I nodi dovrebbero passare a `Ready`:

```
NAME        STATUS   ROLES    AGE     VERSION
worker-1    Ready    <none>   2m30s   v1.31.2
worker-2    Ready    <none>   2m25s   v1.31.2
```

Controlla i pod Flannel:

```bash
kubectl get pods -n kube-system --kubeconfig /var/lib/kubernetes/admin.kubeconfig
```

---

## 9. CoreDNS

Il cluster ha bisogno di DNS interno per la risoluzione dei nomi dei servizi.

Da **cp-1**:

```bash
kubectl --kubeconfig /var/lib/kubernetes/admin.kubeconfig apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: coredns
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  labels:
    kubernetes.io/bootstrapping: rbac-defaults
  name: system:coredns
rules:
- apiGroups:
  - ""
  resources:
  - endpoints
  - services
  - pods
  - namespaces
  verbs:
  - list
  - watch
- apiGroups:
  - ""
  resources:
  - nodes
  verbs:
  - get
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  annotations:
    rbac.authorization.kubernetes.io/autoupdate: "true"
  labels:
    kubernetes.io/bootstrapping: rbac-defaults
  name: system:coredns
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:coredns
subjects:
- kind: ServiceAccount
  name: coredns
  namespace: kube-system
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        errors
        health {
          lameduck 5s
        }
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
          pods insecure
          fallthrough in-addr.arpa ip6.arpa
        }
        prometheus :9153
        forward . /etc/resolv.conf
        cache 30
        loop
        reload
        loadbalance
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: coredns
  namespace: kube-system
  labels:
    k8s-app: kube-dns
spec:
  replicas: 1
  selector:
    matchLabels:
      k8s-app: kube-dns
  template:
    metadata:
      labels:
        k8s-app: kube-dns
    spec:
      priorityClassName: system-cluster-critical
      serviceAccountName: coredns
      tolerations:
      - key: "CriticalAddonsOnly"
        operator: "Exists"
      nodeSelector:
        kubernetes.io/os: linux
      containers:
      - name: coredns
        image: coredns/coredns:1.11.3
        imagePullPolicy: IfNotPresent
        resources:
          limits:
            memory: 170Mi
          requests:
            cpu: 100m
            memory: 70Mi
        args: [ "-conf", "/etc/coredns/Corefile" ]
        volumeMounts:
        - name: config-volume
          mountPath: /etc/coredns
          readOnly: true
        ports:
        - containerPort: 53
          name: dns
          protocol: UDP
        - containerPort: 53
          name: dns-tcp
          protocol: TCP
        - containerPort: 9153
          name: metrics
          protocol: TCP
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
            scheme: HTTP
          initialDelaySeconds: 60
          timeoutSeconds: 5
          successThreshold: 1
          failureThreshold: 5
        readinessProbe:
          httpGet:
            path: /ready
            port: 8181
            scheme: HTTP
      dnsPolicy: Default
      volumes:
      - name: config-volume
        configMap:
          name: coredns
          items:
          - key: Corefile
            path: Corefile
---
apiVersion: v1
kind: Service
metadata:
  name: kube-dns
  namespace: kube-system
  annotations:
    prometheus.io/port: "9153"
    prometheus.io/scrape: "true"
  labels:
    k8s-app: kube-dns
    kubernetes.io/cluster-service: "true"
    kubernetes.io/name: "CoreDNS"
spec:
  selector:
    k8s-app: kube-dns
  clusterIP: 10.96.0.10
  ports:
  - name: dns
    port: 53
    protocol: UDP
  - name: dns-tcp
    port: 53
    protocol: TCP
  - name: metrics
    port: 9153
    protocol: TCP
EOF
```

Verifica:

```bash
kubectl get pods -n kube-system --kubeconfig /var/lib/kubernetes/admin.kubeconfig
```

---

## 10. Smoke Test

Il cluster è vivo. Verifichiamo che funzioni tutto.

### 10.1 Pod nginx

```bash
kubectl --kubeconfig /var/lib/kubernetes/admin.kubeconfig create deployment nginx \
  --image nginx:alpine --replicas 2

kubectl --kubeconfig /var/lib/kubernetes/admin.kubeconfig expose deployment nginx \
  --port 80 --target-port 80 --type NodePort

kubectl --kubeconfig /var/lib/kubernetes/admin.kubeconfig get pods -o wide
kubectl --kubeconfig /var/lib/kubernetes/admin.kubeconfig get svc nginx
```

### 10.2 Verifica comunicazione pod → pod

```bash
# Ottieni IP di un pod
POD_IP=$(kubectl --kubeconfig /var/lib/kubernetes/admin.kubeconfig get pods -l app=nginx \
  -o jsonpath='{.items[0].status.podIP}')
echo $POD_IP

# Fai un ping via kubectl exec
kubectl --kubeconfig /var/lib/kubernetes/admin.kubeconfig run test-pod \
  --image alpine --restart=Never --rm -it -- \
  wget -qO- http://${POD_IP}
```

### 10.3 Verifica DNS

```bash
kubectl --kubeconfig /var/lib/kubernetes/admin.kubeconfig run dns-test \
  --image alpine --restart=Never --rm -it -- \
  nslookup kubernetes.default.svc.cluster.local
```

Output atteso:

```
Server:    10.96.0.10
Address 1: 10.96.0.10 kube-dns.kube-system.svc.cluster.local
Name:      kubernetes.default.svc.cluster.local
Address 1: 10.96.0.1 kubernetes.default.svc.cluster.local
```

### 10.4 Scale up

```bash
kubectl --kubeconfig /var/lib/kubernetes/admin.kubeconfig scale deployment nginx --replicas 5
kubectl --kubeconfig /var/lib/kubernetes/admin.kubeconfig get pods -o wide
```

I pod dovrebbero distribuirsi tra worker-1 e worker-2.

### 10.5 CURL da fuori cluster (dalla tua macchina)

```bash
kubectl --kubeconfig /var/lib/kubernetes/admin.kubeconfig get nodes -o wide
```

Prendi l'IP di un worker e la NodePort del service nginx:

```bash
NODE_PORT=$(kubectl --kubeconfig /var/lib/kubernetes/admin.kubeconfig get svc nginx \
  -o jsonpath='{.spec.ports[0].nodePort}')
echo "NodePort: $NODE_PORT"
```

Dalla tua macchina (host), testa:

```bash
curl http://192.168.56.21:$NODE_PORT
curl http://192.168.56.22:$NODE_PORT
```

### 10.6 Pod su nodo specifico (nodeSelector)

```bash
kubectl --kubeconfig /var/lib/kubernetes/admin.kubeconfig run test-worker-2 \
  --image alpine --restart=Never --rm -it --overrides='
{
  "spec": {
    "nodeName": "worker-2"
  }
}' -- sh -c "hostname && uname -a"
```

---

## 11. Cleanup

Per distruggere tutto:

```bash
# Da cp-1
kubectl --kubeconfig /var/lib/kubernetes/admin.kubeconfig delete deployment nginx
kubectl --kubeconfig /var/lib/kubernetes/admin.kubeconfig delete svc nginx
```

Esci da tutte le VM (`exit`), poi dalla tua macchina:

```bash
vagrant destroy -f
```

Per ricominciare da capo:

```bash
vagrant up
```

---

## Estensioni possibili

Una volta completato il tutorial base, puoi aggiungere:

| Esercizio | Cosa imparerai |
|-----------|---------------|
| **HA Control Plane** | Aggiungere cp-2 e cp-3 con un load balancer (HAProxy/Nginx) |
| **Persistent Storage** | CSI driver (es. NFS o rook-ceph) per volumi persistenti |
| **Ingress Controller** | Nginx Ingress o Traefik per esporre servizi con nomi DNS |
| **Cert-Manager** | Certificati Let's Encrypt automatici per l'Ingress |
| **Prometheus + Grafana** | Monitoring del cluster |
| **ELK / Loki** | Centralizzazione log |
| **OIDC Auth** | Autenticazione tramite Google/GitHub con Dex o Keycloak |
| **Kubernetes Dashboard** | UI amministrativa |
| **Horizontal Pod Autoscaler** | Auto-scaling basato su CPU/memoria |
| **Velero** | Backup e restore del cluster |
| **Kyverno / OPA** | Policy as code |
| **ArgoCD** (già nel repo) | GitOps deployment |
| **Vault CSI Provider** | Secret injection via Vault (già hai vault-demo) |

---

## Riferimenti

- [Kubernetes the Hard Way - Kelsey Hightower](https://github.com/kelseyhightower/kubernetes-the-hard-way)
- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [etcd.io](https://etcd.io/docs/)
- [containerd.io](https://containerd.io/docs/)
- [Flannel on GitHub](https://github.com/flannel-io/flannel)
