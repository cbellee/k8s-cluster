# tf-mikrotik

Terraform stack for MikroTik RouterOS iBGP configuration used by this Kubernetes lab.

## What this manages

- BGP instance: bgp-1
- BGP template: k8s-cluster-template
- iBGP peer connections for kube workers by default
- Optional iBGP peer connections for control planes

This stack is intentionally separate from [tf-k8s-cluster](../tf-k8s-cluster) state.

## Provider

This stack uses the community RouterOS provider:

- Source: terraform-routeros/routeros
- Version pin: ~> 1.99

## Files

- [versions.tf](versions.tf)
- [provider.tf](provider.tf)
- [variables.tf](variables.tf)
- [main.tf](main.tf)
- [outputs.tf](outputs.tf)
- [terraform.tfvars.example](terraform.tfvars.example)

## First-time setup

1. Copy variables:

```bash
cd /home/chris/repos/k8s-cluster/tf-mikrotik
cp terraform.tfvars.example terraform.tfvars
```

2. Edit terraform.tfvars with your router credentials.

3. Initialize Terraform:

```bash
terraform init
```

4. Validate and preview:

```bash
terraform validate
terraform plan
```

## Safe migration from existing router config

Your current export has existing BGP objects already configured. The safest workflow is:

1. Import existing objects into state.
2. Run plan.
3. Adjust variables until plan is minimal.
4. Apply.

### Import helpers

Find IDs on router terminal:

```rsc
:put [/routing/bgp/instance get [find where name="bgp-1"] .id]
:put [/routing/bgp/template get [find where name="k8s-cluster-template"] .id]
:put [/routing/bgp/connection get [find where name="peer-to-k8s-wk-01"] .id]
:put [/routing/bgp/connection get [find where name="peer-to-k8s-wk-02"] .id]
:put [/routing/bgp/connection get [find where name="peer-to-k8s-wk-03"] .id]
```

Import into Terraform:

```bash
terraform import routeros_routing_bgp_instance.k8s <instance-id>
terraform import routeros_routing_bgp_template.k8s <template-id>
terraform import 'routeros_routing_bgp_connection.k8s_peers["kube-wk-01"]' <peer-id-1>
terraform import 'routeros_routing_bgp_connection.k8s_peers["kube-wk-02"]' <peer-id-2>
terraform import 'routeros_routing_bgp_connection.k8s_peers["kube-wk-03"]' <peer-id-3>
```

Then run:

```bash
terraform plan
```

### Exact mapping for your current export

Based on [../vagrant-k8s-cluster/full-export.rsc](../vagrant-k8s-cluster/full-export.rsc), your existing BGP connection names are:

- peer-to-k8s-wk-01
- peer-to-k8s-wk-02
- peer-to-k8s-wk-03

These map into Terraform worker resources:

- routeros_routing_bgp_connection.k8s_peers["kube-wk-01"] <- peer-to-k8s-wk-01 ID
- routeros_routing_bgp_connection.k8s_peers["kube-wk-02"] <- peer-to-k8s-wk-02 ID
- routeros_routing_bgp_connection.k8s_peers["kube-wk-03"] <- peer-to-k8s-wk-03 ID

You can import all 5 objects (instance, template, 3 worker peers) with:

```bash
cd /home/chris/repos/k8s-cluster/tf-mikrotik
chmod +x ./scripts/import_existing_workers.sh
./scripts/import_existing_workers.sh <instance-id> <template-id> <peer-id-wk01> <peer-id-wk02> <peer-id-wk03>
```

If you want to manage control-plane BGP peers too, set:

```hcl
manage_control_plane_peers = true
```

## Apply

```bash
terraform apply
```

## Verify on router

```rsc
/routing bgp connection print detail
/routing bgp session print detail
/routing bgp session print where established
```

## Notes

- The RouterOS BGP resources are powerful but can have edge cases when changing/removing previously set fields.
- Prefer small iterative applies.
- Keep router credentials out of git.
