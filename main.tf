terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.55.0"
    }
  }
  required_version = ">= 1.5.0"
}

# Network Setup

resource "aws_vpc" "eks_vpc" {
  enable_dns_support   = true
  enable_dns_hostnames = true
  region               = var.region
  cidr_block           = "10.0.0.0/16"

  tags = {
    Name = "eks-vpc-${var.region}"
  }
}

data "aws_availability_zones" "available" {
  region = var.region
  state  = "available"
}

locals {
  azs = data.aws_availability_zones.available.names
}

resource "aws_subnet" "public" {
  for_each = toset(local.azs)

  vpc_id                  = aws_vpc.eks_vpc.id
  availability_zone       = each.value
  cidr_block              = cidrsubnet(aws_vpc.eks_vpc.cidr_block, 8, index(local.azs, each.value))
  map_public_ip_on_launch = true

  tags = {
    Name                     = "eks-public-${each.value}"
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "private" {
  for_each = toset(local.azs)

  vpc_id            = aws_vpc.eks_vpc.id
  availability_zone = each.value
  cidr_block        = cidrsubnet(aws_vpc.eks_vpc.cidr_block, 8, index(local.azs, each.value) + length(local.azs))

  tags = {
    Name                              = "eks-private-${each.value}"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.eks_vpc.id

  tags = {
    Name = "eks-igw"
  }
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "eks-nat-eip"
  }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[local.azs[0]].id

  tags = {
    Name = "eks-nat"
  }

  depends_on = [aws_internet_gateway.igw]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.eks_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "eks-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  for_each = toset(local.azs)

  subnet_id      = aws_subnet.public[each.value].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.eks_vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }

  tags = {
    Name = "eks-private-rt"
  }
}

resource "aws_route_table_association" "private" {
  for_each = toset(local.azs)

  subnet_id      = aws_subnet.private[each.value].id
  route_table_id = aws_route_table.private.id
}

# Cluster Setup

resource "aws_eks_cluster" "hg-eks-cluster" {
  name = "hg-eks-cluster"

  access_config {
    authentication_mode = "API"
  }

  role_arn = aws_iam_role.cluster.arn
  version  = "1.35"

  vpc_config {
    subnet_ids = concat(
      values(aws_subnet.public)[*].id,
      values(aws_subnet.private)[*].id
    )
  }

  # Ensure that IAM Role permissions are created before and deleted
  # after EKS Cluster handling. Otherwise, EKS will not be able to
  # properly delete EKS managed EC2 infrastructure such as Security Groups.
  depends_on = [
    aws_iam_role_policy_attachment.cluster_AmazonEKSClusterPolicy,
  ]
}

resource "aws_iam_role" "cluster" {
  name = "eks-cluster-example"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "sts:AssumeRole",
          "sts:TagSession"
        ]
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSClusterPolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.cluster.name
}