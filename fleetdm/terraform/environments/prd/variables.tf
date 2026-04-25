variable "pm_api_url" { type = string }
variable "pm_user" { type = string }
variable "pm_password" { type = string; sensitive = true }
variable "target_node" { type = string }
variable "clone_template" { type = string }
variable "storage" { type = string }
variable "bridge" { type = string }
variable "gateway" { type = string }
variable "ssh_public_key" { type = string }
