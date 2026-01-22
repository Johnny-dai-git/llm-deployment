#!/bin/bash
set -e

echo "===== system 节点预处理开始 ====="

# 获取当前节点的公网 IP
echo ">>> 正在获取公网 IP 地址..."
SYSTEM_NODE_IP=$(curl -s ifconfig.me)

if [ -z "$SYSTEM_NODE_IP" ]; then
    echo "❌ 无法获取公网 IP 地址，请检查网络连接"
    exit 1
fi

echo ">>> 检测到 system node 公网 IP: $SYSTEM_NODE_IP"

# 修改 metallb-ip-pool.yaml，使用当前节点的公网 IP
METALLB_CONFIG="/home/ubuntu/k8s/llm-deployment/control/config/k8s/base/metallb/metallb-ip-pool.yaml"
if [ -f "$METALLB_CONFIG" ]; then
    echo ">>> 修改 metallb-ip-pool.yaml 使用 system node 公网 IP: $SYSTEM_NODE_IP ..."
    sed -i "s|PUBLIC_IP|${SYSTEM_NODE_IP}|g" "$METALLB_CONFIG"
    echo "✔ Modified metallb-ip-pool.yaml"
else
    echo "⚠️  未找到 $METALLB_CONFIG，跳过 IP 替换"
fi

# 这里你可以按需加一些内核参数，比如：
# sudo modprobe br_netfilter || true
# cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
# net.bridge.bridge-nf-call-iptables  = 1
# net.bridge.bridge-nf-call-ip6tables = 1
# net.ipv4.ip_forward                 = 1
# EOF
# sudo sysctl --system

echo "===== system 节点预处理完成 ====="
