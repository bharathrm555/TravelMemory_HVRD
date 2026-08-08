# ---------------------------------------------------------------------------
# Part 1.5 - Resource Output
# Terraform prints these after `apply`. Re-print any time with:
#   terraform output
# ---------------------------------------------------------------------------

output "web_server_public_ip" {
  description = "Public IP of the web server EC2 instance (the assignment deliverable)."
  value       = aws_instance.web.public_ip
}

output "web_server_public_dns" {
  description = "Public DNS name of the web server."
  value       = aws_instance.web.public_dns
}

output "db_server_private_ip" {
  description = "Private IP of the database server - only reachable inside the VPC."
  value       = aws_instance.db.private_ip
}

output "application_url" {
  description = "Open this in your browser once Ansible has finished."
  value       = "http://${aws_instance.web.public_ip}"
}

output "ssh_to_web" {
  description = "Copy-paste command to SSH into the web server."
  value       = "ssh -i ${var.private_key_path} ubuntu@${aws_instance.web.public_ip}"
}

output "ssh_to_db" {
  description = "SSH into the private DB server by jumping through the web server."
  value       = "ssh -i ${var.private_key_path} -J ubuntu@${aws_instance.web.public_ip} ubuntu@${aws_instance.db.private_ip}"
}

output "admin_cidr_allowed_for_ssh" {
  description = "The single IP allowed to SSH into the web server."
  value       = local.admin_cidr
}

output "vpc_id" {
  description = "ID of the created VPC."
  value       = aws_vpc.main.id
}

output "nat_gateway_public_ip" {
  description = "Elastic IP fronting the NAT Gateway."
  value       = aws_eip.nat.public_ip
}

# ---------------------------------------------------------------------------
# Auto-generate the Ansible inventory so you never hand-copy an IP address.
# Written to ../ansible/inventory.ini every time infrastructure changes.
# ---------------------------------------------------------------------------
resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/../ansible/inventory.ini"
  file_permission = "0644"

  content = templatefile("${path.module}/templates/inventory.tmpl", {
    web_public_ip      = aws_instance.web.public_ip
    db_private_ip      = aws_instance.db.private_ip
    ssh_key_path       = pathexpand(var.private_key_path)
    admin_cidr         = local.admin_cidr
    vpc_cidr           = var.vpc_cidr
    public_subnet_cidr = var.public_subnet_cidr
  })
}
