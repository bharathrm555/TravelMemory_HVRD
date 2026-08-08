# ---------------------------------------------------------------------------
# Part 1.4 - Security Groups
#
# A security group is a stateful firewall attached to an instance.
# "Stateful" means: if you allow traffic IN, the reply is automatically
# allowed back OUT. You only ever describe the direction that starts.
# ---------------------------------------------------------------------------

# Auto-detect the public IP of the machine running Terraform, so SSH to the
# web server can be locked to just you (assignment requirement 1.3).
data "http" "my_public_ip" {
  url = "https://checkip.amazonaws.com"
}

locals {
  # Use the manual override if given, otherwise the auto-detected IP.
  admin_cidr = coalesce(
    var.my_ip_cidr,
    "${chomp(data.http.my_public_ip.response_body)}/32",
  )
}

# --- Web server security group ---------------------------------------------
resource "aws_security_group" "web" {
  name        = "${var.project_name}-web-sg"
  description = "Public web server: HTTP from anyone, SSH from admin IP only"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-web-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "web_ssh_from_admin" {
  security_group_id = aws_security_group.web.id
  description       = "ssh - restricted to the administrators IP only"
  cidr_ipv4         = local.admin_cidr
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "web_http" {
  security_group_id = aws_security_group.web.id
  description       = "http - Nginx serves the React frontend to the public"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "web_all_out" {
  security_group_id = aws_security_group.web.id
  description       = "allow all outbound (npm install, apt, MongoDB driver)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# --- Database server security group ----------------------------------------
# Note there is NO rule allowing anything from 0.0.0.0/0. The only way in is
# from the web server's security group. This is the whole point of putting the
# database in a private subnet.
resource "aws_security_group" "db" {
  name        = "${var.project_name}-db-sg"
  description = "Private database server: reachable only from the web server"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-db-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "db_mongo_from_web" {
  security_group_id            = aws_security_group.db.id
  description                  = "MongoDB - only from the web server SG"
  referenced_security_group_id = aws_security_group.web.id
  from_port                    = 27017
  to_port                      = 27017
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "db_ssh_from_web" {
  security_group_id            = aws_security_group.db.id
  description                  = "SSH - only via the web server acting as a bastion/jump host"
  referenced_security_group_id = aws_security_group.web.id
  from_port                    = 22
  to_port                      = 22
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "db_all_out" {
  security_group_id = aws_security_group.db.id
  description       = "Allow outbound via NAT Gateway (apt, MongoDB repo)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
