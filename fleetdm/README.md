# FleetDM on Proxmox: Terraform + Ansible + Pipeline

This repo targets your three-node FleetDM layout:

- fleet-app: 192.168.68.240
- fleet-db: 192.168.68.241
- fleet-redis: 192.168.68.242

## 1. Set all users and passwords in one file

Copy the example credentials file:

```bash
cp ansible/group_vars/all/credentials.yml.example ansible/group_vars/all/credentials.yml
nano ansible/group_vars/all/credentials.yml
```

Set these values there:

- `ansible_user`
- `fleet_mysql_root_user`
- `fleet_mysql_root_password`
- `fleet_mysql_database`
- `fleet_mysql_user`
- `fleet_mysql_password`
- `fleet_redis_user`
- `fleet_redis_password`
- `fleet_server_private_key`
- optional `fleet_admin_email` / `fleet_admin_password`

`credentials.yml` is ignored by Git via `.gitignore`.

For safer storage, encrypt it:

```bash
ansible-vault encrypt ansible/group_vars/all/credentials.yml
```

Run playbooks with:

```bash
ansible-playbook -i ansible/inventory/dev.ini ansible/site.yml --ask-vault-pass
```

## 2. Deploy with Ansible

```bash
cd ansible
ansible-playbook -i inventory/dev.ini site.yml --ask-vault-pass
```

## 3. Terraform

Each environment has its own Terraform folder under:

```text
terraform/environments/dev
terraform/environments/uat
terraform/environments/prd
```

Copy the example tfvars file in the target environment and fill in Proxmox details:

```bash
cd terraform/environments/dev
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform plan
terraform apply
```

## 4. Pipeline

The Azure DevOps pipeline lives at:

```text
pipelines/azure-pipelines.yml
```

Store sensitive Terraform and Ansible values in Azure DevOps secret variables or variable groups. Do not commit real passwords.
