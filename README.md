# Project Aura AI‑driven Under‑utilized Resource Autoscaler

Ephemeral AWS EKS infrastructure + Karpenter autoscaling for cost‑efficient batch/AI workloads.

[![Deploy Status](https://github.com/iEric0228/project-Aura_AI-driven-Under-utilized-Resource-Autoscaler/actions/workflows/cd-cd.yml/badge.svg)](https://github.com/iEric0228/project-Aura_AI-driven-Under-utilized-Resource-Autoscaler/actions/workflows/cd-cd.yml)
[![AWS](https://img.shields.io/badge/AWS-FF9900?style=flat-square&logo=amazon-aws&logoColor=white)](https://aws.amazon.com/)
[![Terraform](https://img.shields.io/badge/Terraform-623CE4?style=flat-square&logo=terraform&logoColor=white)](https://terraform.io/)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-326CE5?style=flat-square&logo=kubernetes&logoColor=white)](https://kubernetes.io/)
[![CI/CD](https://img.shields.io/badge/GitHub%20Actions-blue?style=flat-square&logo=github-actions&logoColor=white)](https://github.com/features/actions)

## Documentation

- **Deep dive**: `ARCHITECTURE.md` (detailed module-by-module explanation, flows, and tradeoffs)
- **CI/CD workflow**: `.github/workflows/cd-cd.yml`

---

## 1. Big Picture

**Type:** Modular Infrastructure‑as‑Code (Terraform) + CI/CD orchestration (GitHub Actions) for ephemeral EKS clusters.

**Problem solved:** Spin up an EKS cluster on demand, run Kubernetes Jobs, autoscale nodes with Karpenter, collect results, then destroy everything to avoid idle cost.

---

## 2. Architecture Overview

### Modular IaC + CI/CD Orchestration

```
┌─────────────────────────────────────────────────────────────┐
│                    CI/CD Layer (GitHub Actions)             │
│  Orchestrates: Deploy → Run → Collect → Destroy             │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│              Infrastructure Layer (Terraform)               │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐     │
│  │   VPC    │→ │   EKS    │→ │   IAM    │→ │  OIDC   │      │
│  │  Module  │  │  Module  │  │  Module  │  │ Provider│      │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘     │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│            Kubernetes Layer (EKS + Karpenter)               │
│  ┌──────────────┐         ┌──────────────┐                  │
│  │   EKS        │         │  Karpenter   │                  │
│  │  Cluster     │◄────────│  Controller │                   │
│  └──────────────┘         └──────────────┘                  │
│       │                          │                          │
│       └──────────┬───────────────┘                          │
│                  ▼                                          │
│         ┌─────────────────┐                                 │
│         │  EC2 Nodes       │                                │
│         │  (Auto-provision)│                                │
│         └─────────────────┘                                 │
└─────────────────────────────────────────────────────────────┘
```

### Repository Layout

```
Aura_AI-driven-Under-utilized-Resource-Autoscaler/
├── ARCHITECTURE.md               # Deep architecture documentation
├── terraform/
│   ├── environments/
│   │   └── dev/                    # Root module (orchestrates all modules)
│   │       ├── main.tf             # Module composition & wiring
│   │       ├── outputs.tf          # Exports values for CI/CD
│   │       ├── get-oidc-thumbprint.py  # Helper script
│   │       └── karpenter-controller-policy.json  # IAM policy
│   └── modules/                    # Reusable Terraform modules
│       ├── VPC/                    # Networking infrastructure
│       ├── EKS/                    # Kubernetes cluster
│       ├── IAM/                    # Karpenter IAM roles
│       └── IAM_EKS/                # EKS cluster/node IAM roles
├── Karpenter/
│   ├── main.yml                    # Karpenter Provisioner CRD
│   ├── app-job.yml                 # Example Kubernetes Job
│   └── gpu-test-job.yml            # GPU test job for autoscaling validation
├── .github/
│   └── workflows/
│       └── cd-cd.yml               # CI/CD pipeline
└── env.example                     # Environment variables template
```

---

## 3. Key Components

- **VPC Module:** Networking (VPC, subnets, NAT, route tables, Karpenter discovery tags)
- **EKS Module:** EKS cluster/node group, outputs (name, endpoint, OIDC issuer, CA)
- **IAM_EKS Module:** IAM roles for EKS cluster/node group (OIDC, least-privilege)
- **IAM Module:** Karpenter controller IAM role (IRSA integration)
- **Karpenter Manifests:** Kubernetes resources for dynamic node provisioning (CPU/GPU)
- **CI/CD Workflow:** Automates deploy, job run, GPU test, log collection, teardown

---

## 4. Data Flow & Communication

### Infrastructure Provisioning Flow

```
Terraform Apply (main.tf)
   ├─ VPC Module → Outputs subnet IDs
   ├─ IAM_EKS Module → Outputs cluster/node role ARNs
   ├─ EKS Module (uses subnet IDs, role ARNs) → Outputs cluster info, OIDC, CA
   ├─ IAM Module (uses OIDC outputs) → Karpenter controller role
   └─ OIDC Provider (uses EKS outputs)
```

### Karpenter Autoscaling Flow

```
1. User/CI/CD creates a Kubernetes Job/Pod
2. Pod is Pending (no node has enough capacity)
3. Karpenter detects the pending pod and selects an instance type
4. Karpenter launches an EC2 instance and the node joins the cluster
5. Pod schedules and runs
6. After nodes are empty for `ttlSecondsAfterEmpty`, Karpenter terminates them
```

### CI/CD Execution Flow

```
1. Checkout Code
2. Configure AWS Credentials (OIDC-based, no secrets!)
3. Terraform Init/Plan/Apply
4. Get Terraform Outputs (cluster name, endpoint, role ARNs)
5. Configure kubectl (connect to EKS cluster)
6. Deploy Karpenter (Helm chart)
7. Wait for Karpenter Ready (health checks)
8. Apply Karpenter Provisioner
9. Deploy App Job and GPU Test Job
10. Wait for Job Completion
11. Collect Metrics and Logs
12. Terraform Destroy (if not 'deploy' only)
13. Generate & Upload Summary Report
```

---

## 5. GPU Autoscaling Test (Optional)

This repo includes `Karpenter/gpu-test-job.yml` as an example job requesting `nvidia.com/gpu: 1`.

**Important:** GPU provisioning requires additional setup (GPU-capable instance types in the Provisioner + NVIDIA device plugin + a compatible AMI). If you haven’t configured GPU nodes yet, this job will remain Pending/fail.

---

## 6. Tech Stack & Dependencies

| Layer           | Technology         | Purpose/Why Used                                  |
|-----------------|-------------------|--------------------------------------------------- |
| Infrastructure  | Terraform, AWS    | Declarative IaC, managed EKS, VPC, IAM, OIDC       |
| Kubernetes      | EKS, Karpenter    | Cluster orchestration, fast autoscaling            |
| CI/CD           | GitHub Actions    | Automated deploy, test, destroy, reporting         |
| Supporting      | Python, jq, bash  | OIDC thumbprint, JSON parsing, scripting           |

---

## 7. Strengths & Tradeoffs

**Strengths:**
- Modular, reusable Terraform modules
- Secure OIDC/IRSA integration (no static secrets)
- Aggressive cost optimization (ephemeral infra, fast scale-down)
- Automated GPU/CPU autoscaling validation in CI/CD
- Detailed summary reports and artifact collection

**Tradeoffs:**
- Initial setup complexity (multi-module, OIDC wiring)
- Cold start time for infra and node provisioning
- Limited to AWS us-east-1 and t3/g4dn instance families by default

---

## 8. Quickstart

### Prerequisites

- **AWS** account with permissions to create: VPC/EKS/IAM/OIDC/EC2
- **Terraform**, **AWS CLI**, **kubectl**, **helm**, **jq**, **python3**
- A GitHub Actions OIDC role (see `.github/workflows/cd-cd.yml` → `role-to-assume`)

### Run via CI/CD (recommended)

1. Fork + clone this repo
2. Ensure the GitHub OIDC role exists (example name: `github-OICD`)
3. Trigger the workflow `.github/workflows/cd-cd.yml` with:\n   - `deploy-and-destroy` (create infra → run jobs → destroy)\n   - `deploy` (create infra only)\n   - `destroy` (destroy infra only)
4. Download the workflow artifact **`deployment-summary`** (includes `summary.md` + JSON snapshots + logs)

### Run locally (Terraform)

```bash
cd terraform/environments/dev
terraform init
terraform apply
```

Then configure kubectl:

```bash
aws eks update-kubeconfig --region us-east-1 --name aura-eks-dev
kubectl get nodes
```

---

## 9. Troubleshooting

### EKS auth: “the server has asked for the client to provide credentials”

This project uses **EKS API authentication** (`authentication_mode = "API"`), so cluster access is governed by **EKS Access Entries**.

- The EKS module creates an access entry and associates `AmazonEKSClusterAdminPolicy` to an **IAM principal ARN** (`admin_principal_arn`).
- In CI/CD, the runtime identity is usually an **STS assumed-role ARN**, which is **not** a valid principal for access entries.

**Fix:** ensure `admin_principal_arn` resolves to the underlying IAM role ARN (e.g. `arn:aws:iam::<account_id>:role/github-OICD`).  
The dev root module now derives this automatically from the caller identity.

### Karpenter: “no security groups exist given constraints”

Your Provisioner selects security groups by tag:

- `karpenter.sh/discovery: aura-eks-dev`

Ensure the **cluster security group** is tagged. The EKS module adds this tag automatically.

### Karpenter: Spot service-linked role error

If you allow Spot (`karpenter.sh/capacity-type: spot`) without the EC2 Spot service-linked role, you may see:

- `AuthFailure.ServiceLinkedRoleCreationNotPermitted`

Either create the service-linked role ahead of time or keep the Provisioner on `on-demand` capacity.

---

## 10. Appendix: Key Files Reference

| File | Purpose |
|------|---------|
| `terraform/environments/dev/main.tf` | Root module - wires all components together |
| `terraform/modules/VPC/main.tf` | Network infrastructure (VPC, subnets, NAT) |
| `terraform/modules/EKS/main.tf` | Kubernetes cluster + node group + access control |
| `terraform/modules/IAM/main.tf` | Karpenter controller IAM role (IRSA) |
| `terraform/modules/IAM_EKS/main.tf` | EKS cluster/node IAM roles |
| `Karpenter/main.yml` | Karpenter Provisioner CRD (defines scaling behavior) |
| `Karpenter/app-job.yml` | Example CPU Job manifest |
| `Karpenter/gpu-test-job.yml` | Example GPU Job manifest (autoscaling test) |
| `.github/workflows/cd-cd.yml` | CI/CD pipeline (deploy → run → destroy) |
| `terraform/environments/dev/get-oidc-thumbprint.py` | Helper script for OIDC provider setup |

---

## Author

**Eric Chiu**  
Portfolio: [Deploy on Demand](https://github.com/iEric0228/cloud-resume)  
LinkedIn: [Eric Chiu](https://www.linkedin.com/in/eric-chiu-a610553a3/)  
GitHub: [@iEric0228](https://github.com/iEric0228)  
Email: [ericchiu0228@gmail.com](mailto:ericchiu0228@gmail.com)
