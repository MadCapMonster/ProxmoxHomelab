variable "proxmox_endpoint" { type = string }
variable "proxmox_api_token" { type = string sensitive = true }
variable "proxmox_node" { type = string }
variable "template_vmid" { type = number }
variable "datastore_id" { type = string }
variable "bridge" { type = string default = "vmbr0" }
variable "ssh_public_key" { type = string }
variable "ci_user" { type = string default = "ubuntu" }
variable "gateway" { type = string }
variable "nameserver" { type = string default = "1.1.1.1" }
variable "cidr" { type = number default = 24 }

variable "fleet_app_ip" { type = string }
variable "fleet_db_ip" { type = string }
variable "fleet_redis_ip" { type = string }
