variable "ssh_public_key_path" {
  description = "Path to the SSH public key that gets access to the VM. You need the matching private key to log in."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "ssh_key_name" {
  description = "Name of the SSH key resource in Verda."
  type        = string
  default     = "obs-demo"
}
