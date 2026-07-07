# tf-k8s-cluster

A Terraform-based libvirt implementation of the working `vagrant-k8s-cluster` setup.

This project keeps the Kubernetes and Cilium provisioning behavior aligned with the existing implementation by reusing the same Ansible playbooks, Cilium values, and BGP manifests under [ansible](./ansible).

## What Terraform replaces

Terraform replaces the Vagrant layer by:

- Creating the six libvirt VMs.
- Cloning each VM disk from a configurable qcow2 base image.
- Injecting the `ubuntu` user, SSH key, apt bootstrap guardrails, and static network config via cloud-init.
- Generating the Ansible inventory and static hosts file.
- Running the same Ansible dependency and bootstrap playbooks via local-exec.
- Exporting a fresh kubeconfig artifact after bootstrap.

## Prerequisites

Install these on the VM host:

- Terraform
- libvirt / QEMU / KVM
- Ansible
- `kubectl`
- SSH public key at `~/.ssh/id_rsa.pub`
- A qcow2 Ubuntu 26.04 base image reachable on the VM host, or a local Bento Ubuntu 26.04 libvirt image under `~/.vagrant.d/boxes`
- Reachable bridge network (default `br0`)

### Host bridge requirement for the 192.168.89.0/24 VM subnet

If your VM host bridge (`br0`) is only configured on `192.168.88.0/24`, VMs with static `192.168.89.x` addresses will not be reachable from the host.

Add a secondary `192.168.89.x/24` address to `br0` in netplan, then apply netplan.

Example from this environment:

- Netplan file: `/etc/netplan/90-NM-9262e758-ee8e-4e1e-98e8-166f6eb9fb0e.yaml`
- `br0` addresses changed from `192.168.88.100/24` to `192.168.88.100/24, 192.168.89.254/24`

Verify after applying:

```bash
ip -4 addr show br0
```

Expected output includes both subnets on `br0`, including `192.168.89.254/24`.

## Layout

- [main.tf](./main.tf): libvirt domains, cloud-init disks, generated inventory, and Ansible orchestration.
- [variables.tf](./variables.tf): cluster sizing, addressing, and Cilium/Kubernetes variables.
- [versions.tf](./versions.tf): Terraform and provider requirements.
- [outputs.tf](./outputs.tf): IP and kubeconfig outputs.
- [terraform.tfvars.example](./terraform.tfvars.example): starting point for local configuration.
- [templates](./templates): cloud-init, hosts, and Ansible inventory templates.
- [ansible](./ansible): copied working Ansible configuration from `vagrant-k8s-cluster`.
- [hosts](./hosts): generated static hosts file consumed by cloud-init and Ansible.
- [artifacts/kubeconfig](./artifacts/kubeconfig): generated after successful bootstrap.

## Configure

Create a tfvars file:

```bash
cd /home/chris/repos/k8s-cluster/tf-k8s-cluster
cp terraform.tfvars.example terraform.tfvars
```

Set at least:

- `bridge`
- `storage_pool`

`base_image_path` is optional:

- If set, Terraform clones that qcow2 image for all nodes.
- If left empty, Terraform attempts to auto-discover a local Bento Ubuntu 26.04 libvirt image under `~/.vagrant.d/boxes`.
- If neither is available, `terraform apply` fails with a clear error.

The default node names and IPs match the current working cluster shape:

- `kube-cp-01..03` at `192.168.89.10..12`
- `kube-wk-01..03` at `192.168.89.20..22`
- API endpoint alias `kube-cluster-01`
- Router/BGP peer `192.168.89.1`

## Build the cluster

```bash
cd /home/chris/repos/k8s-cluster/tf-k8s-cluster
terraform init
terraform apply
```

What happens during `apply`:

1. Terraform creates six libvirt VMs with static bridged IPs.
2. Terraform waits for SSH to come up on all nodes.
3. Terraform runs `ansible/playbooks/kube-dependencies.yml`.
4. Terraform runs `ansible/playbooks/bootstrap-cluster.yml`.
5. Terraform exports a kubeconfig to [artifacts/kubeconfig](./artifacts/kubeconfig).
6. By default, Terraform also updates `~/.kube/config` on the VM host.

## Verify

```bash
kubectl get nodes -o wide
ssh ubuntu@192.168.89.10 "kubectl -n kube-system rollout status ds/cilium --timeout=10m"
ssh ubuntu@192.168.89.10 "kubectl -n kube-system get pods -o wide"
```

## Destroy

```bash
cd /home/chris/repos/k8s-cluster/tf-k8s-cluster
terraform destroy
```

This removes the Terraform-managed VMs and their related libvirt volumes/cloud-init disks. It does not restore any previous `~/.kube/config` backup automatically.

## Notes

- This project intentionally preserves the same Ansible bootstrap logic as the working Vagrant version rather than re-implementing Kubernetes and Cilium configuration in HCL.
- If you want exact OS image parity with the Vagrant flow, either rely on the Bento auto-discovery path or point `base_image_path` at the same Ubuntu 26.04 image family used for your libvirt VMs.
- The copied Ansible assets in this folder can diverge from `vagrant-k8s-cluster` over time. If you change one implementation, update the other deliberately.
