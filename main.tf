terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.55.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "= 4.3.0"
    }
  }
  required_version = ">= 1.5.0"

  # Configure after creating the S3 bucket and DynamoDB table:
  # backend "s3" {
  #   bucket         = "YOUR_TERRAFORM_STATE_BUCKET"
  #   key            = "eks/terraform.tfstate"
  #   region         = "YOUR_REGION"
  #   dynamodb_table = "YOUR_TERRAFORM_LOCK_TABLE"
  #   encrypt        = true
  # }
}

provider "aws" {
  default_tags {
    tags = {
      Project     = "hg-eks"
      ManagedBy   = "terraform"
      Environment = "production"
    }
  }
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

  common_tags = {
    Project     = "hg-eks"
    ManagedBy   = "terraform"
    Environment = "production"
  }
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

# KMS Encryption

resource "aws_kms_key" "eks" {
  description             = "EKS secrets encryption key"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = local.common_tags
}

resource "aws_kms_alias" "eks" {
  name          = "alias/eks-secrets"
  target_key_id = aws_kms_key.eks.key_id
}

# Cluster Setup

resource "aws_eks_cluster" "hg_eks_cluster" {
  name = "hg-eks-cluster"

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  role_arn = aws_iam_role.cluster.arn
  version  = "1.35"

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  encryption_config {
    provider {
      key_arn = aws_kms_key.eks.arn
    }
    resources = ["secrets"]
  }

  vpc_config {
    subnet_ids = concat(
      values(aws_subnet.public)[*].id,
      values(aws_subnet.private)[*].id
    )
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.allowed_cidrs
  }

  # Ensure that IAM Role permissions are created before and deleted
  # after EKS Cluster handling. Otherwise, EKS will not be able to
  # properly delete EKS managed EC2 infrastructure such as Security Groups.
  depends_on = [
    aws_iam_role_policy_attachment.cluster_AmazonEKSClusterPolicy,
  ]

  tags = local.common_tags
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

# OIDC Provider

data "tls_certificate" "eks" {
  url = aws_eks_cluster.hg_eks_cluster.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.hg_eks_cluster.identity[0].oidc[0].issuer

  tags = local.common_tags
}

# VPC CNI IRSA

resource "aws_iam_role" "vpc_cni" {
  name = "eks-vpc-cni-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:kube-system:aws-node"
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "vpc_cni" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.vpc_cni.name
}

# EKS Addons

resource "aws_eks_addon" "vpc_cni" {
  cluster_name             = aws_eks_cluster.hg_eks_cluster.name
  addon_name               = "vpc-cni"
  service_account_role_arn = aws_iam_role.vpc_cni.arn

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.eks_node_group]

  tags = local.common_tags
}

resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.hg_eks_cluster.name
  addon_name   = "coredns"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.eks_node_group]

  tags = local.common_tags
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.hg_eks_cluster.name
  addon_name   = "kube-proxy"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.eks_node_group]

  tags = local.common_tags
}

# Node Group Setup

resource "aws_eks_node_group" "eks_node_group" {
  cluster_name    = aws_eks_cluster.hg_eks_cluster.name
  node_group_name = "hg-eks-node-group"
  node_role_arn   = aws_iam_role.node_group.arn
  subnet_ids     = values(aws_subnet.private)[*].id
  instance_types = ["t3.medium"]
  ami_type       = "AL2023_x86_64_STANDARD"

  disk_size = 20

  scaling_config {
    desired_size = 2
    max_size     = 4
    min_size     = 1
  }

  update_config {
    max_unavailable = 1
  }

  # Ensure that IAM Role permissions are created before and deleted after EKS Node Group handling.
  # Otherwise, EKS will not be able to properly delete EC2 Instances and Elastic Network Interfaces.
  depends_on = [
    aws_iam_role_policy_attachment.node_group_AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.node_group_AmazonEC2ContainerRegistryReadOnly,
  ]
}

resource "aws_iam_role" "node_group" {
  name = "eks-node-group-role"

  assume_role_policy = jsonencode({
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
    Version = "2012-10-17"
  })
}

resource "aws_iam_role_policy_attachment" "node_group_AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.node_group.name
}

resource "aws_iam_role_policy_attachment" "node_group_AmazonEC2ContainerRegistryReadOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.node_group.name
}