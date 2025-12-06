sudo apt install net-tools
#!/bin/bash
set -e

MASTER_IP=$(hostname -I | awk '{print $1}')

echo "使用主节点 IP: $MASTER_IP"

echo "[1/4] 初始化 Kubernetes 控制平面"
sudo kubeadm init --pod-network-cidr=192.168.0.0/16 --control-plane-endpoint=$MASTER_IP

echo "[2/4] 配置 kubectl（当前为 root 用户）"
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

echo "[3/4] 安装 Calico CNI"
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/calico.yaml

echo "[4/4] 显示 join 命令（给 worker 用，调试时能看见）"
sudo kubeadm token create --print-join-command

echo "===== 控制平面初始化完成 ====="

mkdir -p /home/exouser/.kube
cp /etc/kubernetes/admin.conf /home/exouser/.kube/config
chown exouser:exouser /home/exouser/.kube/config


