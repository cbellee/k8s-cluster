variable "libvirt_uri" {
  description = "Libvirt connection URI."
  type        = string
  default     = "qemu:///system"
}

variable "bridge" {
  description = "Existing host bridge used for cluster node connectivity."
  type        = string
  default     = "br0"
}

variable "storage_pool" {
  description = "Libvirt storage pool used for VM disks and cloud-init ISOs."
  type        = string
  default     = "default"
}

variable "base_image_path" {
  description = "Absolute path to the base qcow2 image to clone for all nodes. Leave empty to auto-discover a local Bento Ubuntu 26.04 libvirt image."
  type        = string
  default     = ""
}

variable "base_image_volume_name" {
  description = "Name for the imported base image volume inside the libvirt pool."
  type        = string
  default     = "tf-k8s-base-ubuntu-26.04.qcow2"
}

variable "disk_size_bytes" {
  description = "Per-node disk size in bytes."
  type        = number
  default     = 107374182400
}

variable "ansible_user" {
  description = "User Ansible will connect as."
  type        = string
  default     = "ubuntu"
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key injected into each node."
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "cp_endpoint_alias" {
  description = "Cluster API endpoint alias."
  type        = string
  default     = "kube-cluster-01"
}

variable "primary_control_plane" {
  description = "Primary control-plane node name."
  type        = string
  default     = "kube-cp-01"
}

variable "gateway_ip" {
  description = "Default gateway for the bridged node network."
  type        = string
  default     = "192.168.89.1"
}

variable "dns0_ip" {
  description = "Primary DNS server for the bridged node network."
  type        = string
  default     = "192.168.89.1"
}

variable "netmask_prefix" {
  description = "CIDR prefix length for node IPs."
  type        = number
  default     = 24
}

variable "k8s_version" {
  description = "Kubernetes version installed by kubeadm/apt."
  type        = string
  default     = "1.35.6"
}

variable "k8s_channel" {
  description = "Kubernetes apt channel."
  type        = string
  default     = "1.35"
}

variable "k8s_repo" {
  description = "Kubernetes apt repo URL."
  type        = string
  default     = "https://pkgs.k8s.io/core:/stable:/v1.35/deb/"
}

variable "k8s_url_apt_key" {
  description = "Kubernetes apt Release.key URL."
  type        = string
  default     = "https://pkgs.k8s.io/core:/stable:/v1.35/deb/Release.key"
}

variable "pod_network_cidr" {
  description = "kubeadm pod network CIDR."
  type        = string
  default     = "10.244.0.0/16"
}

variable "service_cidr" {
  description = "kubeadm service CIDR."
  type        = string
  default     = "10.96.0.0/12"
}

variable "cri_socket" {
  description = "Container runtime socket for kubeadm and kubelet."
  type        = string
  default     = "unix:///run/containerd/containerd.sock"
}

variable "cilium_version" {
  description = "Cilium Helm chart version."
  type        = string
  default     = "1.18.3"
}

variable "cilium_cluster_pool_ipv4_cidr" {
  description = "Cilium cluster-pool pod IPAM CIDR."
  type        = string
  default     = "10.0.0.0/8"
}

variable "cilium_reconcile_existing" {
  description = "Whether bootstrap should reconcile an existing Cilium install."
  type        = bool
  default     = false
}

variable "cilium_bgp_enabled" {
  description = "Whether bootstrap should apply Cilium BGP resources."
  type        = bool
  default     = true
}

variable "cilium_bgp_reconcile_existing" {
  description = "Whether bootstrap should reconcile existing Cilium BGP resources."
  type        = bool
  default     = false
}

variable "cilium_bgp_local_asn" {
  description = "Local ASN used by Cilium BGP control plane."
  type        = number
  default     = 64512
}

variable "cilium_bgp_peer_asn" {
  description = "Peer ASN used by Cilium BGP control plane."
  type        = number
  default     = 64512
}

variable "cilium_bgp_peer_address" {
  description = "Router peer IP for Cilium BGP."
  type        = string
  default     = "192.168.89.1"
}

variable "cilium_bgp_cluster_config_name" {
  type    = string
  default = "cilium-bgp-cluster"
}

variable "cilium_bgp_instance_name" {
  type    = string
  default = "instance-64512"
}

variable "cilium_bgp_peer_name" {
  type    = string
  default = "peer-to-mikrotik"
}

variable "cilium_bgp_peer_config_name" {
  type    = string
  default = "cilium-bgp-peer"
}

variable "cilium_bgp_advertisement_name" {
  type    = string
  default = "cilium-bgp-advertisement"
}

variable "cilium_bgp_advertisement_label_key" {
  type    = string
  default = "advertise"
}

variable "cilium_bgp_advertisement_label_value" {
  type    = string
  default = "bgp"
}

variable "cilium_lb_ip_pool_name" {
  type    = string
  default = "cilium-lb-ip-pool"
}

variable "cilium_lb_ip_pool_cidr" {
  description = "LoadBalancer IP pool CIDR advertised by Cilium."
  type        = string
  default     = "172.17.0.0/16"
}

variable "control_planes" {
  description = "Control-plane node definitions."
  type = map(object({
    ip     = string
    vcpu   = number
    memory = number
    mac    = string
  }))
  default = {
    kube-cp-01 = { ip = "192.168.89.10", vcpu = 2, memory = 4096, mac = "52:54:00:89:10:01" }
    kube-cp-02 = { ip = "192.168.89.11", vcpu = 2, memory = 4096, mac = "52:54:00:89:10:02" }
    kube-cp-03 = { ip = "192.168.89.12", vcpu = 2, memory = 4096, mac = "52:54:00:89:10:03" }
  }
}

variable "workers" {
  description = "Worker node definitions."
  type = map(object({
    ip     = string
    vcpu   = number
    memory = number
    mac    = string
  }))
  default = {
    kube-wk-01 = { ip = "192.168.89.20", vcpu = 2, memory = 4096, mac = "52:54:00:89:20:01" }
    kube-wk-02 = { ip = "192.168.89.21", vcpu = 2, memory = 4096, mac = "52:54:00:89:20:02" }
    kube-wk-03 = { ip = "192.168.89.22", vcpu = 2, memory = 4096, mac = "52:54:00:89:20:03" }
  }
}

variable "export_kubeconfig_to_home" {
  description = "Whether to overwrite the VM host ~/.kube/config after bootstrap."
  type        = bool
  default     = true
}

variable "autostart" {
  description = "Whether libvirt should autostart the domains."
  type        = bool
  default     = true
}
