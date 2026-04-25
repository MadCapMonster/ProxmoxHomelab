variable "proxmox_endpoint" { type = string }
variable "proxmox_api_token" { type = string; sensitive = true }
variable "proxmox_insecure_tls" { type = bool; default = true }
variable "proxmox_node" { type = string }
variable "template_id" { type = number }
variable "datastore_id" { type = string }
variable "bridge" { type = string; default = "vmbr0" }
variable "gateway" { type = string }
variable "dns_servers" { type = list(string) }
variable "ssh_user" { type = string; default = "ansible" }
variable "ssh_public_keys" { type = list(string) }
variable "vm_base_id" { type = number }
variable "fleet_app_ip" { type = string }
variable "fleet_db_ip" { type = string }
variable "fleet_redis_ip" { type = string }
