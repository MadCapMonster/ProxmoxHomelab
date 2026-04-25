terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.70"
    }
  }
}

resource "proxmox_virtual_environment_vm" "vm" {
  name        = var.name
  description = "Managed by Terraform"
  node_name   = var.node_name
  vm_id       = var.vm_id
  tags        = var.tags

  clone {
    vm_id = var.template_id
    full  = true
  }

  cpu { cores = var.cpu_cores }
  memory { dedicated = var.memory_mb }

  disk {
    datastore_id = var.datastore_id
    interface    = "scsi0"
    size         = var.disk_gb
  }

  initialization {
    ip_config {
      ipv4 {
        address = var.ipv4_cidr
        gateway = var.gateway
      }
    }
    user_account {
      username = var.ssh_user
      keys     = var.ssh_public_keys
    }
    dns { servers = var.dns_servers }
  }

  network_device {
    bridge = var.bridge
    model  = "virtio"
  }

  agent { enabled = true }
  started = true
}

output "ipv4_address" { value = var.ipv4_cidr }
output "name" { value = proxmox_virtual_environment_vm.vm.name }
