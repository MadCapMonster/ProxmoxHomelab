terraform {
  required_version = ">= 1.6.0"
  required_providers { proxmox = { source = "bpg/proxmox", version = "~> 0.70" } }
  backend "azurerm" {}
}
provider "proxmox" { endpoint = var.proxmox_endpoint, api_token = var.proxmox_api_token, insecure = var.proxmox_insecure_tls }
locals {
  env = "prd"
  vms = {
    app   = { name = "fleet-app-prd",   vm_id = var.vm_base_id + 1, ip = var.fleet_app_ip,   cores = 2, memory = 4096, disk = 40 }
    db    = { name = "fleet-db-prd",    vm_id = var.vm_base_id + 2, ip = var.fleet_db_ip,    cores = 2, memory = 4096, disk = 80 }
    redis = { name = "fleet-redis-prd", vm_id = var.vm_base_id + 3, ip = var.fleet_redis_ip, cores = 1, memory = 2048, disk = 20 }
  }
}
module "fleet_vms" {
  for_each = local.vms
  source = "../../modules/proxmox-vm"
  name = each.value.name
  node_name = var.proxmox_node
  vm_id = each.value.vm_id
  template_id = var.template_id
  datastore_id = var.datastore_id
  bridge = var.bridge
  cpu_cores = each.value.cores
  memory_mb = each.value.memory
  disk_gb = each.value.disk
  ipv4_cidr = "${each.value.ip}/24"
  gateway = var.gateway
  dns_servers = var.dns_servers
  ssh_user = var.ssh_user
  ssh_public_keys = var.ssh_public_keys
  tags = ["fleetdm", local.env, each.key]
}
