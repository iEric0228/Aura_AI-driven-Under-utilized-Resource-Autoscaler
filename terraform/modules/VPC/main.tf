resource "aws_vpc" "this" {
  cidr_block           = var.cidr_block
  enable_dns_support   = var.enable_dns_support
  enable_dns_hostnames = var.enable_dns_hostnames
  tags                 = var.tags
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = var.tags
}

resource "aws_eip" "nat" {
  count = 1
  tags  = merge(var.tags, { "Name" = "${var.name}-nat-eip-${count.index + 1}" })
}

resource "aws_subnet" "public" {
  count                   = length(var.public_subnets)
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnets[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true
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

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { "Name" = "${var.name}-private-rt" })
}

resource "aws_route" "public_internet_access" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route" "private_nat_access" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[0].id
}

resource "aws_route_table_association" "public" {
  for_each      = { for idx, cidr in var.public_subnets : idx => cidr }
  subnet_id     = aws_subnet.public[each.key].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  for_each      = { for idx, cidr in var.private_subnets : idx => cidr }
  subnet_id     = aws_subnet.private[each.key].id
  route_table_id = aws_route_table.private.id
}

resource "aws_nat_gateway" "this" {
  count         = 1
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = merge(var.tags, { "Name" = "${var.name}-nat-gateway-${count.index + 1}" })
  depends_on    = [aws_internet_gateway.this]
}