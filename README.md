# EKS Cluster — Terraform

Production-grade AWS EKS cluster provisioned with Terraform.

## Architecture

```
VPC (10.0.0.0/16)
├── Public subnets (x3 AZs)  — NAT Gateway, internet-facing Load Balancers
└── Private subnets (x3 AZs) — EKS nodes, pods
        │
        └── NAT Gateway → Internet Gateway → Internet
```

### Components

| Component | Description |
|-----------|-------------|
| VPC | Dedicated VPC with DNS support and hostnames enabled |
| Subnets | 3 public + 3 private subnets, one per AZ |
| Internet Gateway | Single IGW for internet access |
| NAT Gateway | Single NAT GW (in first AZ) for outbound node/pod traffic |
| EKS Cluster | Managed control plane, Kubernetes 1.35, API-only auth mode |
| KMS Key | Encrypts Kubernetes secrets at rest |
| OIDC Provider | Enables IRSA (pod-level IAM roles) |
| Node Group | Managed node group in private subnets, `t3.medium`, AL2023 |
| EKS Addons | `vpc-cni` (with IRSA), `coredns`, `kube-proxy` |

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5.0
- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) configured with appropriate permissions
- IAM permissions to create VPC, EKS, IAM, and KMS resources

## Usage

### 1. Create a `terraform.tfvars` file

```hcl
region        = "eu-north-1"
allowed_cidrs = ["YOUR_IP/32"]  # Restrict API endpoint access to your IP
```

> **Do not commit `terraform.tfvars` to version control.** It is already listed in `.gitignore`.

### 2. (Optional) Configure remote state

Uncomment and configure the `backend "s3"` block in `main.tf` after creating:
- An S3 bucket for state storage
- A DynamoDB table for state locking

### 3. Deploy

```bash
terraform init
terraform plan
terraform apply
```

### 4. Connect to the cluster

```bash
aws eks update-kubeconfig --region eu-north-1 --name hg-eks-cluster
kubectl get nodes
```

## Variables

| Name | Description | Default |
|------|-------------|---------|
| `region` | AWS region to deploy into | `eu-north-1` |
| `allowed_cidrs` | CIDRs allowed to reach the EKS API public endpoint | — |

## Security

- EKS authentication uses **API mode only** (no `aws-auth` ConfigMap)
- API endpoint restricted to `allowed_cidrs` — set to your IP, not `0.0.0.0/0`
- Nodes run in **private subnets** — not directly reachable from internet
- Kubernetes secrets encrypted at rest with a dedicated KMS key (automatic rotation enabled)
- VPC CNI uses **IRSA** — pod-level IAM, not node-level
- All CloudWatch log types enabled: `api`, `audit`, `authenticator`, `controllerManager`, `scheduler`

## CI/CD

A GitHub Actions workflow runs on every PR touching `.tf` or `.tfvars` files:

- `terraform fmt -check` — enforces consistent formatting
- `tflint` — lints for provider-specific and general issues

See [.github/workflows/terraform-ci.yml](.github/workflows/terraform-ci.yml).