#!/usr/bin/env bash
set -euxo pipefail

exec > >(tee -a /var/log/clearroots-worker-bootstrap.log)
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

run_mssh() {
  mssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
    -t "${master_id}" -r "${region}" "ubuntu@${master_id}" "$@"
}

hostnamectl set-hostname kube-worker

apt_install apt-transport-https ca-certificates curl gpg docker.io python3 python3-pip mssh debian-keyring debian-archive-keyring

mkdir -p /etc/apt/keyrings
retry 5 bash -c "curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg"
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' | tee /etc/apt/sources.list.d/kubernetes.list

apt_install kubelet=1.29.0-1.1 kubeadm=1.29.0-1.1 kubectl=1.29.0-1.1 kubernetes-cni
apt-mark hold kubelet kubeadm kubectl

systemctl enable docker
systemctl start docker
usermod -aG docker ubuntu

retry 5 pip3 install --upgrade pyopenssl ec2instanceconnectcli

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

echo "Waiting for master API and node readiness..."
until run_mssh "kubectl get nodes --no-headers 2>/dev/null | awk 'NR==1 {print \$2}'" | grep -q Ready; do
  sleep 10
done

echo "Retrieving join token..."
TOKEN=""
until [[ -n "$${TOKEN}" ]]; do
  TOKEN="$(run_mssh "kubeadm token create 2>/dev/null || kubeadm token list | awk 'NR==2 {print \$1}'" | tr -d '\r' | tail -n1)"
  sleep 2
done

echo "Retrieving CA hash..."
CA_HASH=""
until [[ -n "$${CA_HASH}" ]]; do
  CA_HASH="$(run_mssh "openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -hex | sed 's/^.* //'" | tr -d '\r' | tail -n1)"
  sleep 2
done

kubeadm join "${master_private}:6443" \
  --token "$${TOKEN}" \
  --discovery-token-ca-cert-hash "sha256:$${CA_HASH}" \
  --ignore-preflight-errors=All

retry 5 bash -c "curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg"
retry 5 bash -c "curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list"
apt_install caddy

mkdir -p /etc/caddy
cat <<EOF >/etc/caddy/Caddyfile
${domain_name} {
    encode gzip zstd
    reverse_proxy 127.0.0.1:30080
}
EOF

systemctl enable caddy
systemctl restart caddy
systemctl is-active caddy

echo "Worker bootstrap completed successfully."