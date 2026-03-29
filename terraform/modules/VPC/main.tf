resource "aws_vpc" "this" {
  cidr_block           = var.cidr_block
  enable_dns_support   = var.enable_dns_support
  enable_dns_hostnames = var.enable_dns_hostnames
  tags                 = merge(var.tags, { "Name" = var.name })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { "Name" = "${var.name}-igw" })
}

locals {
  nat_count = var.enable_ha_nat ? length(var.public_subnets) : 1
}

resource "aws_eip" "nat" {
  count = local.nat_count
  tags  = merge(var.tags, { "Name" = "${var.name}-nat-eip-${count.index + 1}" })
}

resource "aws_subnet" "public" {
  count                   = length(var.public_subnets)
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnets[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = false
  tags = merge(
    var.tags,
    {
      "Name"                              = "${var.name}-public-${count.index + 1}",
      "kubernetes.io/cluster/${var.name}" = "shared",
      "kubernetes.io/role/elb"            = "1",
      "karpenter.sh/discovery"            = var.name
    }
  )
}

resource "aws_subnet" "private" {
  count             = length(var.private_subnets)
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnets[count.index]
  availability_zone = var.availability_zones[count.index]
  tags = merge(
    var.tags,
    {
      "Name"                              = "${var.name}-private-${count.index + 1}",
      "kubernetes.io/cluster/${var.name}" = "shared",
      "kubernetes.io/role/internal-elb"   = "1",
      "karpenter.sh/discovery"            = var.name
    }
  )
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { "Name" = "${var.name}-public-rt" })
}

# Per-AZ private route tables for HA NAT gateway support
resource "aws_route_table" "private" {
  count  = local.nat_count
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { "Name" = "${var.name}-private-rt-${count.index + 1}" })
}

resource "aws_route" "public_internet_access" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route" "private_nat_access" {
  count                  = local.nat_count
  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[count.index].id
}

resource "aws_route_table_association" "public" {
  count          = length(var.public_subnets)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = length(var.private_subnets)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index % local.nat_count].id
}

resource "aws_nat_gateway" "this" {
  count         = local.nat_count
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = merge(var.tags, { "Name" = "${var.name}-nat-gateway-${count.index + 1}" })
  depends_on    = [aws_internet_gateway.this]
}
