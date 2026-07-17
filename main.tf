terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.55.0"
    }
  }
  required_version = ">= 1.5.0"
}

resource "aws_vpc" "eks_vpc" {
  region     = var.region
  cidr_block = "10.0.0.0/16"

  tags = {
    Name = "eks-vpc-${var.region}"
  }
}

data "aws_availability_zones" "available" {
  region = var.region
  state = "available"
}

locals {
  azs = data.aws_availability_zones.available.names
}

resource "aws_subnet" "eks_subnet" {
  for_each = toset(local.azs)
  vpc_id              = aws_vpc.eks_vpc.id
  availability_zone   = each.value
  cidr_block          = cidrsubnet(aws_vpc.eks_vpc.cidr_block, 8, index(local.azs, each.value))
}

resource "aws_eks_cluster" "hg-eks-cluster" {
  name = "hg-eks-cluster"

  access_config {
    authentication_mode = "API"
  }

  role_arn = aws_iam_role.cluster.arn
  version  = "1.35"

  vpc_config {
    subnet_ids = values(aws_subnet.eks_subnet)[*].id
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