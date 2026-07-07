data "local_file" "ssh_public_key" {
  filename = pathexpand(var.ssh_public_key_path)
}

data "external" "bento_image" {
  program = ["/usr/bin/env", "bash", "${path.module}/scripts/discover_bento_image.sh"]
}

locals {
  cp_endpoint_node = var.primary_control_plane
  nodes            = merge(var.control_planes, var.workers)
  resolved_base_image_path = trimspace(var.base_image_path) != "" ? pathexpand(var.base_image_path) : trimspace(try(data.external.bento_image.result.path, ""))
  hosts_content = templatefile("${path.module}/templates/hosts.tftpl", {
    nodes             = local.nodes
    cp_endpoint_node  = local.cp_endpoint_node
    cp_endpoint_alias = var.cp_endpoint_alias
  })
}

resource "local_file" "hosts" {
  filename = "${path.module}/hosts"
  content  = local.hosts_content
}

resource "local_file" "ansible_inventory" {
  filename = "${path.module}/ansible/inventory/hosts.ini"
  content = templatefile("${path.module}/templates/inventory_hosts.ini.tftpl", {
    primary_control_plane               = var.primary_control_plane
    control_planes                      = var.control_planes
    workers                             = var.workers
    ansible_user                        = var.ansible_user
    cp_endpoint_alias                   = var.cp_endpoint_alias
    cp_endpoint_node                    = local.cp_endpoint_node
    k8s_version                         = var.k8s_version
    k8s_channel                         = var.k8s_channel
    k8s_repo                            = var.k8s_repo
    k8s_url_apt_key                     = var.k8s_url_apt_key
    pod_network_cidr                    = var.pod_network_cidr
    service_cidr                        = var.service_cidr
    cri_socket                          = var.cri_socket
    cilium_version                      = var.cilium_version
    cilium_cluster_pool_ipv4_cidr       = var.cilium_cluster_pool_ipv4_cidr
    cilium_reconcile_existing           = var.cilium_reconcile_existing
    cilium_bgp_enabled                  = var.cilium_bgp_enabled
    cilium_bgp_reconcile_existing       = var.cilium_bgp_reconcile_existing
    cilium_bgp_local_asn                = var.cilium_bgp_local_asn
    cilium_bgp_peer_asn                 = var.cilium_bgp_peer_asn
    cilium_bgp_peer_address             = var.cilium_bgp_peer_address
    cilium_bgp_cluster_config_name      = var.cilium_bgp_cluster_config_name
    cilium_bgp_instance_name            = var.cilium_bgp_instance_name
    cilium_bgp_peer_name                = var.cilium_bgp_peer_name
    cilium_bgp_peer_config_name         = var.cilium_bgp_peer_config_name
    cilium_bgp_advertisement_name       = var.cilium_bgp_advertisement_name
    cilium_bgp_advertisement_label_key  = var.cilium_bgp_advertisement_label_key
    cilium_bgp_advertisement_label_value = var.cilium_bgp_advertisement_label_value
    cilium_lb_ip_pool_name              = var.cilium_lb_ip_pool_name
    cilium_lb_ip_pool_cidr              = var.cilium_lb_ip_pool_cidr
  })
}

resource "libvirt_volume" "base_image" {
  name   = var.base_image_volume_name
  pool   = var.storage_pool
  type   = "file"

  target = {
    format = {
      type = "qcow2"
    }
  }

  create = {
    content = {
      url = local.resolved_base_image_path
    }
  }

  lifecycle {
    precondition {
      condition     = local.resolved_base_image_path != ""
      error_message = "No base image found. Set base_image_path in terraform.tfvars or ensure a local Bento Ubuntu 26.04 libvirt image exists under ~/.vagrant.d/boxes."
    }
  }
}

resource "libvirt_volume" "node_disk" {
  for_each      = local.nodes
  name          = "${each.key}.qcow2"
  pool          = var.storage_pool
  type          = "file"
  capacity      = var.disk_size_bytes
  capacity_unit = "bytes"

  target = {
    format = {
      type = "qcow2"
    }
  }

  backing_store = {
    path = libvirt_volume.base_image.path
    format = {
      type = "qcow2"
    }
  }
}

resource "libvirt_cloudinit_disk" "node_init" {
  for_each = local.nodes
  name     = "${each.key}-cloudinit.iso"
  user_data = templatefile("${path.module}/templates/user_data.yaml.tftpl", {
    ansible_user   = var.ansible_user
    ssh_public_key = trimspace(data.local_file.ssh_public_key.content)
    hosts_content  = local.hosts_content
  })
  meta_data = yamlencode({
    instance_id    = each.key
    local_hostname = each.key
  })
  network_config = templatefile("${path.module}/templates/network_config.yaml.tftpl", {
    mac     = each.value.mac
    ip      = each.value.ip
    prefix  = var.netmask_prefix
    gateway = var.gateway_ip
    dns     = var.dns0_ip
  })
}

resource "libvirt_domain" "node" {
  for_each  = local.nodes
  name      = each.key
  type      = "kvm"
  memory    = each.value.memory
  memory_unit = "MiB"
  vcpu      = each.value.vcpu
  autostart = var.autostart

  features = {
    acpi = true
  }

  os = {
    firmware     = "efi"
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "pc-i440fx-plucky"
  }

  devices = {
    disks = [
      {
        device = "disk"
        driver = {
          name = "qemu"
          type = "qcow2"
        }
        source = {
          volume = {
            pool   = var.storage_pool
            volume = libvirt_volume.node_disk[each.key].name
          }
        }
        target = {
          bus = "virtio"
          dev = "vda"
        }
      },
      {
        device = "cdrom"
        source = {
          file = {
            file = libvirt_cloudinit_disk.node_init[each.key].path
          }
        }
        target = {
          bus = "sata"
          dev = "sda"
        }
      }
    ]

    interfaces = [
      {
        model = {
          type = "virtio"
        }
        mac = {
          address = each.value.mac
        }
        source = {
          bridge = {
            bridge = var.bridge
          }
        }
        wait_for_ip = {
          timeout = 300
          source  = "any"
        }
      }
    ]

    consoles = [
      {
        target = {
          type = "serial"
          port = 0
        }
      }
    ]

    graphics = [
      {
        vnc = {
          auto_port = true
        }
      }
    ]
  }
}

resource "terraform_data" "wait_for_ssh" {
  for_each = local.nodes

  depends_on = [terraform_data.start_domains]

  triggers_replace = [
    libvirt_domain.node[each.key].name,
    each.value.ip,
  ]

  provisioner "local-exec" {
    command = <<-EOT
      for i in $(seq 1 60); do
        ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 ${var.ansible_user}@${each.value.ip} 'echo ready' >/dev/null 2>&1 && exit 0
        sleep 5
      done
      echo "SSH not ready on ${each.key} (${each.value.ip})" >&2
      exit 1
    EOT
    interpreter = ["/usr/bin/env", "bash", "-c"]
  }
}

resource "terraform_data" "start_domains" {
  for_each = local.nodes

  triggers_replace = [
    libvirt_domain.node[each.key].name,
  ]

  provisioner "local-exec" {
    command = <<-EOT
      state=$(virsh domstate ${each.key} 2>/dev/null || true)
      if [ "$state" != "running" ]; then
        virsh start ${each.key}
      fi
    EOT
    interpreter = ["/usr/bin/env", "bash", "-c"]
  }
}

resource "terraform_data" "kube_dependencies" {
  depends_on = [
    local_file.ansible_inventory,
    local_file.hosts,
    terraform_data.wait_for_ssh,
  ]

  triggers_replace = [
    for name, domain in libvirt_domain.node : "${name}:${domain.name}"
  ]

  provisioner "local-exec" {
    command     = "cd ${path.module}/ansible && ansible-playbook -i ./inventory/hosts.ini playbooks/kube-dependencies.yml"
    interpreter = ["/usr/bin/env", "bash", "-c"]
  }
}

resource "terraform_data" "bootstrap_cluster" {
  depends_on = [terraform_data.kube_dependencies]

  triggers_replace = [
    sha1(local_file.ansible_inventory.content),
    sha1(file("${path.module}/ansible/playbooks/bootstrap-cluster.yml")),
    sha1(file("${path.module}/ansible/cilium/cilium-values.yaml")),
  ]

  provisioner "local-exec" {
    command     = "cd ${path.module}/ansible && ansible-playbook -i ./inventory/hosts.ini playbooks/bootstrap-cluster.yml"
    interpreter = ["/usr/bin/env", "bash", "-c"]
  }
}

resource "terraform_data" "export_kubeconfig" {
  depends_on = [terraform_data.bootstrap_cluster]

  triggers_replace = [
    libvirt_domain.node[var.primary_control_plane].name,
    local.nodes[var.primary_control_plane].ip,
  ]

  provisioner "local-exec" {
    command = <<-EOT
      mkdir -p ${path.module}/artifacts
      ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${var.ansible_user}@${local.nodes[var.primary_control_plane].ip} 'cat /home/${var.ansible_user}/.kube/config' > ${path.module}/artifacts/kubeconfig
      KUBECONFIG=${path.module}/artifacts/kubeconfig kubectl config set-cluster kubernetes --server=https://${local.nodes[var.primary_control_plane].ip}:6443 >/dev/null
      if [ "${var.export_kubeconfig_to_home}" = "true" ]; then
        mkdir -p $HOME/.kube
        cp $HOME/.kube/config $HOME/.kube/config.bak.$(date +%Y%m%d%H%M%S) 2>/dev/null || true
        cp ${path.module}/artifacts/kubeconfig $HOME/.kube/config
      fi
    EOT
    interpreter = ["/usr/bin/env", "bash", "-c"]
  }
}
