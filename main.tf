terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.55.0"
    }
  }
  required_version = ">= 1.5.0"
}

resource "aws_vpc" "main" {
  region     = var.region
  cidr_block = "10.0.0.0/16"

  tags = {
    Name = "eks-vpc-${var.region}"
  }
}