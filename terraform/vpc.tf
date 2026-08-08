# ---------------------------------------------------------------------------
# Part 1.2 - VPC and Network Configuration
#   - one VPC
#   - one PUBLIC subnet  (web server, reachable from the internet)
#   - one PRIVATE subnet (database, NOT reachable from the internet)
#   - Internet Gateway   (gives the public subnet 2-way internet access)
#   - NAT Gateway        (gives the private subnet OUTBOUND-only internet,
#                         so MongoDB can be downloaded / patched)
#   - a route table for each subnet
# ---------------------------------------------------------------------------

# Availability zones available in this region; we pin everything to the first
# one so the two instances can talk over the local network cheaply.
data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

# --- Internet Gateway: the VPC's door to the public internet ----------------
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

# --- Subnets ----------------------------------------------------------------

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true # anything launched here gets a public IP

  tags = {
    Name = "${var.project_name}-public-subnet"
    Tier = "public"
  }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidr
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = {
    Name = "${var.project_name}-private-subnet"
    Tier = "private"
  }
}

# --- NAT Gateway ------------------------------------------------------------
# A NAT Gateway needs its own static public IP (an Elastic IP) and must itself
# sit in a PUBLIC subnet. Private instances then route their outbound traffic
# through it, which is how they reach the internet without being reachable
# FROM the internet.

resource "aws_eip" "nat" {
  domain     = "vpc"
  depends_on = [aws_internet_gateway.main]

  tags = {
    Name = "${var.project_name}-nat-eip"
  }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  depends_on    = [aws_internet_gateway.main]

  tags = {
    Name = "${var.project_name}-nat-gw"
  }
}

# --- Route tables -----------------------------------------------------------

# Public route table: "anything not local -> send to the Internet Gateway"
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.project_name}-public-rt"
  }
}

# Private route table: "anything not local -> send to the NAT Gateway"
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name = "${var.project_name}-private-rt"
  }
}

# A route table only takes effect once it is ASSOCIATED with a subnet.
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}
