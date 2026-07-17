variable "region" {
  type        = string
  description = "The AWS region to deploy resources in."
  default     = "eu-north-1"
}

variable "allowed_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to access the EKS API endpoint"
}