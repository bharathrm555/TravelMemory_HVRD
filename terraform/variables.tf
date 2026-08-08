# ---------------------------------------------------------------------------
# Input variables - change these in terraform.tfvars, not here.
# ---------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "ap-south-1" # Mumbai
}

variable "project_name" {
  description = "Short name used as a prefix for every resource name."
  type        = string
  default     = "travelmemory"
}

variable "owner_name" {
  description = "Your name - shows up in resource tags."
  type        = string
  default     = "bharath"
}

# --- Networking -------------------------------------------------------------

variable "vpc_cidr" {
  description = "IP address range for the whole VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "IP range for the public subnet (web server lives here)."
  type        = string
  default     = "10.0.1.0/24"
}

variable "private_subnet_cidr" {
  description = "IP range for the private subnet (database lives here)."
  type        = string
  default     = "10.0.2.0/24"
}

# --- Compute ----------------------------------------------------------------

variable "instance_type" {
  description = "EC2 size. t3.micro is free-tier eligible in most accounts."
  type        = string
  default     = "t3.micro"
}

variable "public_key_path" {
  description = "Path to the SSH PUBLIC key uploaded to AWS."
  type        = string
  default     = "~/.ssh/travelmemory.pub"
}

variable "private_key_path" {
  description = "Path to the matching SSH PRIVATE key, used by Ansible."
  type        = string
  default     = "~/.ssh/travelmemory"
}

# --- Access control ---------------------------------------------------------

variable "my_ip_cidr" {
  description = <<-EOT
    Your home/office public IP in CIDR form, e.g. "203.0.113.45/32".
    Leave as null and Terraform auto-detects it via checkip.amazonaws.com.
    The assignment requires SSH to the public instance be locked to YOUR IP.
  EOT
  type        = string
  default     = null
}
