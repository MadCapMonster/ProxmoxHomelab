# FleetDM on Proxmox: discovery + Terraform + Ansible + Azure DevOps

This starter repo assumes three VMs per environment:

- fleet-app
- fleet-db
- fleet-redis

## 1. Discover existing setup

Run this on each current VM:

```bash
sudo ./scripts/discover_fleetdm_setup.sh
```

Review the output for secrets before committing it.

## 2. Terraform

Edit `terraform/environments/<env>/terraform.tfvars` and `backend.hcl` from the examples.

```bash
cd terraform/environments/dev
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

## 3. Ansible

Edit `ansible/inventory/<env>.yml` and `ansible/group_vars/all.yml`. Put secrets in Ansible Vault.

```bash
ansible-galaxy collection install community.general community.mysql
ansible-playbook -i ansible/inventory/dev.yml ansible/site.yml
```

## 4. Pipeline

Use `pipelines/azure-pipelines.yml`. Store secrets as pipeline variables or variable groups:

- `PROXMOX_API_TOKEN`
- SSH private key for Ansible
- Ansible Vault password/secret file handling

## Notes

- The Fleet server needs MySQL, Redis, and TLS material.
- Keep `FLEET_SERVER_PRIVATE_KEY` stable when migrating existing Fleet data.
- Replace placeholder IPs, Proxmox template ID, datastore, DNS, certificates, and domain names.
