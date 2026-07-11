# Project Aura AI-driven Under-utilized Resource Autoscaler

Ephemeral AWS EKS infrastructure + Karpenter autoscaling for cost-efficient batch/AI workloads.

[![Deploy Status](https://github.com/iEric0228/Aura_AI-driven-Under-utilized-Resource-Autoscaler/actions/workflows/ci-cd.yml/badge.svg)](https://github.com/iEric0228/Aura_AI-driven-Under-utilized-Resource-Autoscaler/actions/workflows/ci-cd.yml)
[![AWS](https://img.shields.io/badge/AWS-FF9900?style=flat-square&logo=amazon-aws&logoColor=white)](https://aws.amazon.com/)
[![Terraform](https://img.shields.io/badge/Terraform-623CE4?style=flat-square&logo=terraform&logoColor=white)](https://terraform.io/)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-326CE5?style=flat-square&logo=kubernetes&logoColor=white)](https://kubernetes.io/)
[![CI/CD](https://img.shields.io/badge/GitHub%20Actions-blue?style=flat-square&logo=github-actions&logoColor=white)](https://github.com/features/actions)

## Documentation

- **Deep dive**: `ARCHITECTURE.md` (detailed module-by-module explanation, flows, and tradeoffs)
- **CI/CD workflow**: `.github/workflows/ci-cd.yml`

---

## 1. Big Picture

**Type:** Modular Infrastructure-as-Code (Terraform) + CI/CD orchestration (GitHub Actions) for ephemeral EKS clusters.

**Problem solved:** Spin up an EKS cluster on demand, run Kubernetes Jobs, autoscale nodes with Karpenter, collect results, then destroy everything to avoid idle cost.

---

## 2. Architecture Overview

### Modular IaC + CI/CD Orchestration

```
+-------------------------------------------------------------+
|                    CI/CD Layer (GitHub Actions)               |
|  Orchestrates: Deploy -> Run -> Collect -> Destroy           |
|  Features: OIDC auth, concurrency control, GPU diagnostics   |
+-------------------------------------------------------------+
                            |
                            v
+-------------------------------------------------------------+
|              Infrastructure Layer (Terraform)                 |
|  +----------+  +----------+  +----------+  +----------+     |
|  |   VPC    |->|   EKS    |->|   IAM    |->|  OIDC    |     |
|  |  Module  |  |  Module  |  |  Module  |  | Provider |     |
|  +----------+  +----------+  +----------+  +----------+     |
|  3 AZs, HA NAT  Logging,     Least-priv    IRSA for         |
|  /20 subnets    private EP   iam:PassRole   Karpenter        |
+-------------------------------------------------------------+
                            |
                            v
+-------------------------------------------------------------+
|            Kubernetes Layer (EKS + Karpenter)                |
|  +----------------+         +----------------+               |
|  |   EKS Cluster  |         |   Karpenter    |               |
|  |   v1.31        |<--------|   v0.37.0      |               |
|  +----------------+         +----------------+               |
|       |                          |                           |
|       +----------+---------------+                           |
|                  v                                           |
|         +-----------------+  +-------------------+           |
|         | CPU NodePool    |  | GPU NodePool      |           |
|         | t3/m5/m6i       |  | g4dn/g5           |           |
|         | spot+on-demand  |  | on-demand only    |           |
|         +-----------------+  +-------------------+           |
|                                                              |
|  Security: NetworkPolicy, metadata endpoint blocked          |
+-------------------------------------------------------------+
```

### Repository Layout

```
Aura_AI-driven-Under-utilized-Resource-Autoscaler/
├── ARCHITECTURE.md                    # Deep architecture documentation
├── terraform/
│   ├── environments/
│   │   └── dev/                       # Root module (orchestrates all modules)
│   │       ├── main.tf                # Module composition & wiring
│   │       ├── variables.tf           # Configurable inputs with validation
│   │       ├── outputs.tf             # Exports values for CI/CD
│   │       └── get-oidc-thumbprint.py # OIDC helper (SHA-256)
│   └── modules/                       # Reusable Terraform modules
│       ├── VPC/                       # Networking (3 AZs, HA NAT support)
│       ├── EKS/                       # Kubernetes cluster + logging + access
│       ├── IAM/                       # Karpenter IAM roles (IRSA)
│       └── IAM_EKS/                   # EKS cluster/node IAM roles
├── Karpenter/
│   ├── main.yml                       # NodePool + EC2NodeClass (CPU & GPU)
│   ├── app-job.yml                    # Example CPU Job
│   ├── gpu-test-job.yml               # GPU test job for autoscaling validation
│   ├── nvidia-device-plugin.yml       # Vendored NVIDIA device plugin DaemonSet
│   └── network-policy.yml             # Default-deny + metadata endpoint block
├── scripts/
│   ├── bootstrap-backend.sh           # S3 + DynamoDB backend setup
│   └── local-test.sh                  # Local validation & testing
├── .github/
│   └── workflows/
│       └── ci-cd.yml                  # CI/CD pipeline
└── env.example                        # Environment variables template
```

---

## 3. Key Components

- **VPC Module:** 3-AZ networking with public/private subnets (/20 private for autoscaling headroom), optional HA NAT gateways, Karpenter discovery tags
- **EKS Module:** EKS v1.31 cluster with API authentication, control plane logging, private endpoint access, configurable public CIDR restrictions
- **IAM_EKS Module:** Least-privilege IAM roles for EKS cluster and node groups
- **IAM Module:** Karpenter controller IAM role via IRSA, `iam:PassRole` scoped to node role only
- **Karpenter Manifests:** NodePool/EC2NodeClass for CPU and GPU workloads with disruption budgets, node expiry, and AL2023 AMIs
- **Network Policies:** Default-deny ingress + EC2 metadata endpoint block for pod security
- **CI/CD Workflow:** OIDC-authenticated pipeline with concurrency control, GPU quota checks, diagnostics, and artifact collection

---

## 4. Data Flow & Communication

### Infrastructure Provisioning Flow

```
Terraform Apply (main.tf)
   ├─ VPC Module -> Outputs subnet IDs (3 AZs, /20 private subnets)
   ├─ IAM_EKS Module -> Outputs cluster/node role ARNs
   ├─ EKS Module (uses subnet IDs, role ARNs) -> Cluster info, OIDC, CA
   ├─ OIDC Provider (uses EKS outputs) -> IRSA trust relationship
   └─ IAM Module (uses OIDC outputs) -> Karpenter controller role
```

### Karpenter Autoscaling Flow

```
1. User/CI/CD creates a Kubernetes Job/Pod
2. Pod is Pending (no node has enough capacity)
3. Karpenter detects the pending pod and selects an instance type
4. Karpenter launches an EC2 instance and the node joins the cluster
5. Pod schedules and runs
6. After nodes are empty for 60s (consolidateAfter), Karpenter terminates them
7. Nodes expire after 720h (30 days) for drift prevention
```

### CI/CD Execution Flow

```
 1. Checkout Code
 2. Configure AWS Credentials (OIDC-based, no secrets in repo)
 3. Bootstrap Terraform Backend (S3 + DynamoDB, idempotent)
 4. Terraform Init/Plan/Apply
 5. Validate Terraform Outputs
 6. Configure kubectl
 7. Deploy Karpenter (Helm v0.37.0 via OCI registry)
 8. Install NVIDIA Device Plugin (vendored manifest)
 9. Apply Network Policies
10. Apply Karpenter NodePools + EC2NodeClasses
11. Deploy CPU Job + GPU Test Job (with quota check)
12. Monitor GPU Node Provisioning (up to 7 min timeout)
13. Wait for Job Completion
14. Collect Cluster Metrics and Logs
15. Pre-destroy Cleanup (terminate Karpenter instances)
16. Terraform Destroy
17. Generate & Upload Summary Report
```

---

## 5. Security

| Feature | Implementation |
|---------|---------------|
| **Authentication** | GitHub OIDC -> AWS STS (no static credentials) |
| **Authorization** | EKS API access entries, least-privilege IAM policies |
| **Network** | Private subnets for nodes, configurable public API CIDRs |
| **Pod Security** | NetworkPolicy default-deny, EC2 metadata endpoint blocked |
| **IAM Scoping** | `iam:PassRole` scoped to node role ARN only |
| **Supply Chain** | Pinned container images, vendored NVIDIA plugin, bounded provider versions |
| **Logging** | EKS control plane logs (api, audit, authenticator, controllerManager, scheduler) |
| **State** | S3 backend with encryption, versioning, DynamoDB locking |
| **Secrets** | Role ARN via GitHub Actions secret (`AWS_ROLE_ARN`), no hardcoded credentials |

---

## 6. GPU Autoscaling Test

This repo includes `Karpenter/gpu-test-job.yml` as an example job requesting `nvidia.com/gpu: 1`.

**Important:** GPU instances (g4dn, g5) have a **default quota of 0 vCPUs** in most AWS accounts. You must request a quota increase before GPU tests will work:

1. Go to [AWS Service Quotas Console](https://console.aws.amazon.com/servicequotas/home/services/ec2/quotas)
2. Search for **"Running On-Demand G and VT instances"**
3. Request at least **4 vCPUs** (for g4dn.xlarge)

The CI/CD workflow automatically checks GPU quotas and skips the GPU test if insufficient.

---

## 7. Tech Stack & Dependencies

| Layer | Technology | Version | Purpose |
|-------|-----------|---------|---------|
| IaC | Terraform | ~> 1.5 | Declarative infrastructure provisioning |
| Cloud | AWS (EKS, VPC, IAM) | Provider ~> 5.0 | Managed Kubernetes, networking, identity |
| Kubernetes | EKS | 1.31 | Container orchestration |
| Autoscaling | Karpenter | 0.37.0 | Node autoscaling (v1beta1 API) |
| GPU | NVIDIA Device Plugin | 0.14.1 | GPU resource exposure on nodes |
| AMI | Amazon Linux 2023 | Latest | Node operating system |
| CI/CD | GitHub Actions | - | Automated deploy, test, destroy |
| Auth | AWS OIDC + IRSA | - | Secure role assumption |
| Scripts | Python 3, Bash, jq | - | OIDC thumbprint, JSON parsing |

---

## 8. Strengths & Tradeoffs

**Strengths:**
- Modular, reusable Terraform modules with full parameterization
- Secure OIDC/IRSA integration (no static secrets anywhere)
- Production-hardened: HA NAT support, 3 AZs, control plane logging, network policies
- Aggressive cost optimization (ephemeral infra, 60s consolidation, node expiry)
- Automated GPU/CPU autoscaling validation with quota pre-checks
- Least-privilege IAM with scoped `iam:PassRole`
- Detailed summary reports and artifact collection
- Concurrency-safe CI/CD pipeline

**Tradeoffs:**
- Initial setup complexity (multi-module, OIDC wiring, GitHub secret)
- Cold start time for infrastructure and node provisioning (~5-10 min)
- Single-region by default (configurable via variables)
- GPU Spot instances disabled by default due to high interruption rates

### Cost profile

The point of the design: **cost accrues per run, not per month.**

| State | What bills | ~Rate |
|-------|-----------|-------|
| Between runs | nothing — the whole stack is destroyed | $0 |
| Stack up, idle | EKS control plane + NAT | ~$0.15/hr |
| GPU job running | + `g5.xlarge` node(s), Karpenter-provisioned on demand | ~$1.01/hr each |

Karpenter consolidation (60s window) and node expiry keep GPU nodes from
outliving their workload; the pipeline's final stage destroys everything else.
Leaving a `g5.xlarge` idle around the clock would cost ~$725/mo — the
scale-to-zero design exists so that number never appears on a bill.

---

## 9. Quickstart

### Prerequisites

- **AWS** account with permissions to create: VPC/EKS/IAM/OIDC/EC2
- **Tools:** Terraform (>= 1.5), AWS CLI, kubectl, helm, jq, python3
- A GitHub Actions OIDC role configured for your repository

### Setup

1. Fork + clone this repo
2. Create a GitHub Actions secret:
   - **Name:** `AWS_ROLE_ARN`
   - **Value:** `arn:aws:iam::<YOUR_ACCOUNT_ID>:role/<YOUR_OIDC_ROLE_NAME>`
3. (Optional) Update `terraform/environments/dev/variables.tf` defaults for your environment

### Run via CI/CD (recommended)

Trigger the workflow `.github/workflows/ci-cd.yml` via **Actions > Run workflow** with:
- `deploy-and-destroy` — create infra, run jobs, destroy (default)
- `deploy` — create infra only (leaves cluster running)
- `destroy` — destroy existing infra only

Download the **`deployment-summary`** artifact for cluster metrics, logs, and job results.

### Run locally

```bash
# Bootstrap Terraform backend (one-time)
./scripts/bootstrap-backend.sh

# Run local test suite
./scripts/local-test.sh              # Interactive mode
./scripts/local-test.sh --plan-only  # Validate without applying
./scripts/local-test.sh --auto-destroy  # Apply, test, then destroy
```

Or manually:

```bash
cd terraform/environments/dev

# The S3 backend is a partial config; supply the account-specific bucket at init.
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
terraform init \
  -backend-config="bucket=aura-terraform-state-${ACCOUNT_ID}" \
  -backend-config="dynamodb_table=aura-terraform-locks"
terraform apply

# Configure kubectl
aws eks update-kubeconfig --region us-east-1 --name aura-eks-dev
kubectl get nodes
```

### Configuration

Key variables in `terraform/environments/dev/variables.tf`:

| Variable | Default | Description |
|----------|---------|-------------|
| `aws_region` | `us-east-1` | AWS region |
| `cluster_name` | `aura-eks-dev` | EKS cluster name |
| `kubernetes_version` | `1.31` | Kubernetes version |
| `enable_ha_nat` | `false` | HA NAT gateways (one per AZ) |
| `endpoint_public_access_cidrs` | `["0.0.0.0/0"]` | Restrict EKS API access |
| `cluster_log_types` | All 5 types | Control plane logging |

---

## 10. Troubleshooting

### EKS auth: "the server has asked for the client to provide credentials"

This project uses **EKS API authentication** (`authentication_mode = "API"`), so cluster access is governed by **EKS Access Entries**.

- The EKS module creates access entries for the CI/CD role and an optional local admin user.
- In CI/CD, the runtime identity is an **STS assumed-role ARN**, which is automatically resolved to the underlying IAM role ARN.

**Fix:** Ensure your IAM identity has an access entry. For local access, set `local_admin_username` in variables.

### Karpenter: "no security groups exist given constraints"

Karpenter selects security groups by tag: `karpenter.sh/discovery: <cluster_name>`

Ensure the **cluster security group** is tagged. The EKS module adds this tag automatically.

### Karpenter: Spot service-linked role error

If Spot capacity is enabled and you see `AuthFailure.ServiceLinkedRoleCreationNotPermitted`:

```bash
aws iam create-service-linked-role --aws-service-name spot.amazonaws.com
```

### GPU: Nodes not provisioning

1. Check your GPU service quota (default is 0 vCPUs for G instances)
2. The CI/CD workflow logs detailed diagnostics under "Monitor GPU Node Provisioning"
3. See GPU section above for quota increase instructions

---

## 11. Key Files Reference

| File | Purpose |
|------|---------|
| `terraform/environments/dev/main.tf` | Root module - wires all components together |
| `terraform/environments/dev/variables.tf` | Configurable inputs with validation |
| `terraform/modules/VPC/main.tf` | Network infrastructure (3 AZs, HA NAT, /20 subnets) |
| `terraform/modules/EKS/main.tf` | EKS cluster + logging + access control + node group |
| `terraform/modules/IAM/main.tf` | Karpenter controller IAM role (IRSA) |
| `terraform/modules/IAM_EKS/main.tf` | EKS cluster/node IAM roles + instance profile |
| `Karpenter/main.yml` | NodePool + EC2NodeClass (CPU & GPU, AL2023, disruption budgets) |
| `Karpenter/network-policy.yml` | Default-deny ingress + metadata endpoint block |
| `Karpenter/nvidia-device-plugin.yml` | Vendored NVIDIA device plugin DaemonSet (v0.14.1) |
| `Karpenter/app-job.yml` | Example CPU Job manifest |
| `Karpenter/gpu-test-job.yml` | GPU test Job manifest (nvidia-smi) |
| `.github/workflows/ci-cd.yml` | CI/CD pipeline (deploy, run, collect, destroy) |
| `scripts/bootstrap-backend.sh` | One-time S3 + DynamoDB backend setup |
| `scripts/local-test.sh` | Local validation and testing script |

---

## Author

**Eric Chiu**
Portfolio: [Deploy on Demand](https://github.com/iEric0228/cloud-resume)
LinkedIn: [Eric Chiu](https://www.linkedin.com/in/eric-chiu-a610553a3/)
GitHub: [@iEric0228](https://github.com/iEric0228)
Email: [ericchiu0228@gmail.com](mailto:ericchiu0228@gmail.com)
