#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ ! -f terraform/terraform.tfvars ]]; then
  echo "Copy terraform/terraform.tfvars.example to terraform/terraform.tfvars and edit it first."
  exit 1
fi

terraform -chdir=terraform init
terraform -chdir=terraform apply -auto-approve

ansible-galaxy collection install -r ansible/requirements.yml
ansible-playbook -i ansible/inventory/hosts.ini ansible/site.yml
