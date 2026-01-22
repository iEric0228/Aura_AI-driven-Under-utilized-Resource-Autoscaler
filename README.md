# Project Aura_AI-driven-Under-utilized-Resource-Autoscaler

AI-Ops Infrastructure on AWS EKS

[![Deploy Status](https://github.com/iEric0228/project-Aura_AI-driven-Under-utilized-Resource-Autoscaler/actions/workflows/cd-cd.yml/badge.svg)](https://github.com/iEric0228/project-Aura_AI-driven-Under-utilized-Resource-Autoscaler/actions/workflows/cd-cd.yml)
[![AWS](https://img.shields.io/badge/AWS-FF9900?style=flat-square&logo=amazon-aws&logoColor=white)](https://aws.amazon.com/)
[![Terraform](https://img.shields.io/badge/Terraform-623CE4?style=flat-square&logo=terraform&logoColor=white)](https://terraform.io/)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-326CE5?style=flat-square&logo=kubernetes&logoColor=white)](https://kubernetes.io/)
[![CI/CD](https://img.shields.io/badge/GitHub%20Actions-blue?style=flat-square&logo=github-actions&logoColor=white)](https://github.com/features/actions)

---

## 1. Big Picture

**Type:** Cloud infrastructure automation for AI workloads (EKS, GPU, ephemeral infra)

**Problem Solved:**
- Enables cost-efficient, on-demand provisioning of GPU resources for LLM jobs
- Automates full lifecycle (deploy, test, destroy) with secure, modular, production-ready Terraform and GitHub Actions

---

## 2. Architecture Overview

### Modular Infrastructure-as-Code with CI/CD Orchestration

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

### Directory Structure

```
Aura_AI-driven-Under-utilized-Resource-Autoscaler/
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
1. User/CI/CD creates a Kubernetes Job (CPU or GPU)
2. Pod is Pending (no node with required resources)
3. Karpenter detects need, provisions node (CPU or GPU instance)
4. Node registers, pod runs
5. After job completes + TTL, Karpenter scales node down
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

## 5. GPU Autoscaling Test

- The pipeline includes a GPU test job (`gpu-test-job.yml`) that requests a GPU node.
- The CI/CD summary report will show if a GPU node was provisioned and the test ran successfully.
- This validates end-to-end autoscaling for both CPU and GPU workloads.

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

1. Fork and clone this repo
2. Set up AWS OIDC role for GitHub Actions (see `.github/workflows/cd-cd.yml`)
3. Edit `env.example` and copy to `.env` with your settings
4. Trigger the GitHub Actions workflow (`deploy-and-destroy`)
5. Review the summary report for autoscaling and GPU test results

---

## 9. Appendix: Key Files Reference

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
