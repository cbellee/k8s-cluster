MAJOR_VERSION=1.30
MINOR_VERSION=2
PATCH_VERSION=1.1
# pager /etc/apt/sources.list.d/kubernetes.list
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v$MAJOR_VERSION/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
curl -fsSL https://pkgs.k8s.io/core:/stable:/v$MAJOR_VERSION/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

sudo apt update
apt-cache madison kubeadm

sudo kubeadm upgrade plan

# replace x in 1.27.x-* with the latest patch version
sudo apt-mark unhold kubeadm && \
sudo apt-get update && sudo apt-get install -y kubeadm=$MAJOR_VERSION.$MINOR_VERSION-$PATCH_VERSION && \
sudo apt-mark hold kubeadm

sudo kubeadm version 
sudo kubeadm upgrade plan
sudo kubeadm upgrade apply v$MAJOR_VERSION.$MINOR_VERSION

sudo apt-mark unhold kubectl kubelet && \
sudo apt-get update && sudo apt-get install -y kubectl=$MAJOR_VERSION.$MINOR_VERSION-$PATCH_VERSION kubelet=$MAJOR_VERSION.$MINOR_VERSION-$PATCH_VERSION && \
sudo apt-mark hold kubelet kubectl

sudo systemctl daemon-reload
sudo systemctl restart kubelet

kubectl get nodes