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