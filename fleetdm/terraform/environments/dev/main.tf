terraform {
  required_version = ">= 1.6.0"
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "~> 3.0"
    }
  }
}

provider "proxmox" {
  pm_api_url      = var.pm_api_url
  pm_user         = var.pm_user
  pm_password     = var.pm_password
  pm_tls_insecure = true
}

module "fleet_app" {
  source         = "../../modules/proxmox_vm"
  name           = "fleet-app-dev"
  vmid           = 240
  target_node    = var.target_node
  clone_template = var.clone_template
  cores          = 2
  memory         = 4096
  disk_size      = "30G"
  storage        = var.storage
  bridge         = var.bridge
  ip_address     = "192.168.68.240"
  gateway        = var.gateway
  ssh_public_key = var.ssh_public_key
}

module "fleet_db" {
  source         = "../../modules/proxmox_vm"
  name           = "fleet-db-dev"
  vmid           = 241
  target_node    = var.target_node
  clone_template = var.clone_template
  cores          = 2
  memory         = 4096
  disk_size      = "40G"
  storage        = var.storage
  bridge         = var.bridge
  ip_address     = "192.168.68.241"
  gateway        = var.gateway
  ssh_public_key = var.ssh_public_key
}

module "fleet_redis" {
  source         = "../../modules/proxmox_vm"
  name           = "fleet-redis-dev"
  vmid           = 242
  target_node    = var.target_node
  clone_template = var.clone_template
  cores          = 1
  memory         = 2048
  disk_size      = "20G"
  storage        = var.storage
  bridge         = var.bridge
  ip_address     = "192.168.68.242"
  gateway        = var.gateway
  ssh_public_key = var.ssh_public_key
}
