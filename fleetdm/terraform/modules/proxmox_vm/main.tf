terraform {
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "~> 3.0"
    }
  }
}

resource "proxmox_vm_qemu" "vm" {
  name        = var.name
  target_node = var.target_node
  clone       = var.clone_template
  vmid        = var.vmid

  agent   = 1
  os_type = "cloud-init"

  cores  = var.cores
  memory = var.memory

  scsihw = "virtio-scsi-pci"

  disks {
    scsi {
      scsi0 {
        disk {
          size    = var.disk_size
          storage = var.storage
        }
      }
    }
  }

  network {
    model  = "virtio"
    bridge = var.bridge
  }

  ipconfig0 = "ip=${var.ip_address}/24,gw=${var.gateway}"

  ciuser  = "ubuntu"
  sshkeys = var.ssh_public_key
}
