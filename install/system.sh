#!/bin/bash
set -e

echo "===== system 节点预处理开始 ====="

# 这里你可以按需加一些内核参数，比如：
# sudo modprobe br_netfilter || true
# cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
# net.bridge.bridge-nf-call-iptables  = 1
# net.bridge.bridge-nf-call-ip6tables = 1
# net.ipv4.ip_forward                 = 1
# EOF
# sudo sysctl --system

echo "当前暂时没有额外配置，直接退出。"
echo "===== system 节点预处理完成 ====="

