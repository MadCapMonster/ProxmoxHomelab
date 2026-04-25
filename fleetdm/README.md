# FleetDM on Proxmox: Terraform + Ansible one-click starter

This repo is a starter kit for deploying a 3-VM FleetDM stack on Proxmox:

- `fleet-app`
- `fleet-db`
- `fleet-redis`

It also creates a host enrolment script you can run on Ubuntu/Debian VMs or LXCs to join Fleet as a host.

## Workflow

1. Create a Proxmox cloud-init Ubuntu/Debian template with QEMU guest agent installed.
2. Fill in `terraform/terraform.tfvars`.
3. Run `./scripts/deploy.sh`.
4. Log in to `https://<fleet_app_ip>:8080` or `http://<fleet_app_ip>:8080` depending on your reverse proxy/TLS setup.
5. Generate/set an enrol secret, then run `./scripts/render-enrol-script.sh`.

## Important

This is a homelab-friendly baseline. For production, add TLS, backups, firewalling, restricted DB/Redis network ACLs, proper secret management, monitoring, and Fleet license/config as required.
