#!/usr/bin/env bash
set -euxo pipefail

exec > >(tee -a /var/log/clearroots-master-bootstrap.log)
exec 2>&1

export DEBIAN_FRONTEND=noninteractive

retry() {
  local attempts="$1"
  shift
  local n=1
  until "$@"; do
    if [[ $n -ge $attempts ]]; then
      echo "Command failed after $${attempts} attempts: $*"
      return 1
    fi
    echo "Attempt $${n} failed. Retrying in 10 seconds: $*"
    n=$((n + 1))
    sleep 10
  done
}

wait_for_apt() {
  while fuser /var/lib/dpkg/lock >/dev/null 2>&1 \
    || fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
    || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
    echo "Waiting for apt lock..."
    sleep 5
  done
}

apt_install() {
  wait_for_apt
  retry 5 apt-get update -y
  wait_for_apt
  retry 5 apt-get install -y "$@"
}

hostnamectl set-hostname kube-master

apt_install apt-transport-https ca-certificates curl gpg docker.io

mkdir -p /etc/apt/keyrings
retry 5 bash -c "curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg"
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' | tee /etc/apt/sources.list.d/kubernetes.list

apt_install kubelet=1.29.0-1.1 kubeadm=1.29.0-1.1 kubectl=1.29.0-1.1 kubernetes-cni
apt-mark hold kubelet kubeadm kubectl

systemctl enable docker
systemctl start docker
usermod -aG docker ubuntu

cat <<EOF >/etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

cat <<EOF >/etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system

mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml >/dev/null
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
systemctl enable containerd
systemctl restart containerd

swapoff -a || true
sed -ri '/\sswap\s/s/^#?/#/' /etc/fstab || true

retry 5 kubeadm config images pull
kubeadm init --pod-network-cidr=10.244.0.0/16 --ignore-preflight-errors=All

mkdir -p /home/ubuntu/.kube
cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
chown -R ubuntu:ubuntu /home/ubuntu/.kube

retry 5 sudo -i -u ubuntu kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
retry 5 sudo -i -u ubuntu kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.26/deploy/local-path-storage.yaml
sudo -i -u ubuntu kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' || true

mkdir -p /home/ubuntu/clearroots
cat <<MANIFEST >/home/ubuntu/clearroots/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: clearroots-web
  namespace: default
  labels:
    app: clearroots-web
    project: clearroots-foundation
spec:
  replicas: 2
  selector:
    matchLabels:
      app: clearroots-web
  template:
    metadata:
      labels:
        app: clearroots-web
    spec:
      containers:
      - name: clearroots-web
        image: ${container_image}
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 80
        resources:
          requests:
            memory: "64Mi"
            cpu: "100m"
          limits:
            memory: "128Mi"
            cpu: "200m"
MANIFEST

cat <<'MANIFEST' >/home/ubuntu/clearroots/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: clearroots-web-service
  namespace: default
  labels:
    app: clearroots-web
    project: clearroots-foundation
spec:
  type: NodePort
  selector:
    app: clearroots-web
  ports:
  - protocol: TCP
    port: 80
    targetPort: 80
    nodePort: 30080
MANIFEST

chown -R ubuntu:ubuntu /home/ubuntu/clearroots

echo "Master bootstrap completed successfully."
echo "Next step:"
echo "sudo -i -u ubuntu kubectl apply -f /home/ubuntu/clearroots/"
