locals {
  vms = {
    fleet-app = {
      vm_id  = 1240
      ip     = var.fleet_app_ip
      cores  = 2
      memory = 4096
      disk   = 32
    }
    fleet-db = {
      vm_id  = 1241
      ip     = var.fleet_db_ip
      cores  = 2
      memory = 4096
      disk   = 64
    }
    fleet-redis = {
      vm_id  = 1242
      ip     = var.fleet_redis_ip
      cores  = 1
      memory = 2048
      disk   = 16
    }
  }
}

resource "proxmox_virtual_environment_vm" "fleet" {
  for_each = local.vms

  name      = each.key
  node_name = var.proxmox_node
  vm_id     = each.value.vm_id
  tags      = ["fleetdm", "terraform"]

  clone {
    vm_id = var.template_vmid
    full  = true
  }

  agent { enabled = true }

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory
  }

  disk {
    datastore_id = var.datastore_id
    interface    = "scsi0"
    size         = each.value.disk
    discard      = "on"
  }

  network_device {
    bridge = var.bridge
    model  = "virtio"
  }

  initialization {
    datastore_id = var.datastore_id

    ip_config {
      ipv4 {
        address = "${each.value.ip}/${var.cidr}"
        gateway = var.gateway
      }
    }

    dns {
      servers = [var.nameserver]
    }

    user_account {
      username = var.ci_user
      keys     = [var.ssh_public_key]
    }
  }
}

resource "local_file" "ansible_inventory" {
  filename = "../ansible/inventory/hosts.ini"
  content = templatefile("${path.module}/templates/hosts.ini.tftpl", {
    ci_user        = var.ci_user
    fleet_app_ip   = var.fleet_app_ip
    fleet_db_ip    = var.fleet_db_ip
    fleet_redis_ip = var.fleet_redis_ip
  })
}
