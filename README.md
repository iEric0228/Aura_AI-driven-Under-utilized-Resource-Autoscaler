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

## 2. Core Architecture

- **Layered Modular IaC:** Each AWS resource (VPC, EKS, IAM, IAM_EKS) is a separate Terraform module
- **Root Environment:** `/terraform/environments/dev/` wires modules together
- **CI/CD Orchestration:** `.github/workflow/cd-cd.yml` automates deploy/test/destroy

```
Karpenter/         # Karpenter CRDs and job manifests
terraform/
  environments/
    dev/           # Root config, outputs for CI/CD
  modules/
    VPC/           # VPC resources
    EKS/           # EKS cluster, node group, outputs
    IAM/           # Karpenter controller IAM role
    IAM_EKS/       # EKS cluster/node IAM roles
.github/
  workflow/        # CI/CD pipeline
```

---

## 3. Key Components

- **VPC Module:** Networking (VPC, subnets, NAT, route tables)
- **EKS Module:** EKS cluster/node group, outputs (name, endpoint, OIDC issuer, CA)
- **IAM_EKS Module:** IAM roles for EKS cluster/node group (OIDC, least-privilege)
- **IAM Module:** Karpenter controller IAM role (OIDC integration)
- **Karpenter Manifests:** Kubernetes resources for dynamic GPU node provisioning
- **CI/CD Workflow:** Automates deploy, job run, log collection, teardown

---

## 4. Data Flow & Communication

```
Terraform Root (main.tf)
   ├─ VPC Module → Outputs subnet IDs
   ├─ IAM_EKS Module → Outputs cluster/node role ARNs
   ├─ EKS Module (uses subnet IDs, role ARNs) → Outputs cluster info, OIDC, CA
   ├─ IAM Module (uses OIDC outputs) → Karpenter controller role
   └─ OIDC Provider (uses EKS outputs)
```

**CI/CD Flow:**
```
GitHub Actions Workflow
   ├─ Triggers Terraform deploy (creates VPC, EKS, IAM, OIDC)
   ├─ Deploys Karpenter and job manifests to EKS
   ├─ Karpenter provisions GPU nodes as needed
   ├─ Job runs, logs collected
   └─ Terraform destroy (tears down all resources)
```

---

## 5. Tech Stack & Dependencies

- **AWS:** EKS, EC2, EFS, IAM
- **Terraform:** Modular, environment-based IaC
- **Karpenter:** Advanced Kubernetes autoscaler
- **GitHub Actions:** CI/CD automation with OIDC
- **Kubernetes:** Container orchestration for LLM jobs

---

## 6. Execution Flow Example

1. **CI/CD Trigger:** User starts GitHub Actions workflow, specifying job parameters
2. **Terraform Deploy:** Provisions VPC, EKS, IAM roles, OIDC provider
3. **Cluster Ready:** EKS cluster is up, OIDC provider configured, IAM roles attached
4. **Karpenter Deploy:** Karpenter controller and provisioner CRDs applied
5. **Job Launch:** Llama 3 job manifest deployed; Karpenter provisions GPU nodes
6. **Job Execution:** Model runs, logs and resource IDs collected
7. **Teardown:** Workflow runs `terraform destroy` to remove all resources

---

## 7. Strengths & Tradeoffs

**Strengths:**
- Highly modular and maintainable Terraform codebase
- No circular dependencies; clean separation of concerns
- Secure OIDC integration for CI/CD
- Cost-optimized: ephemeral infra, spot GPU support, zero baseline nodes
- Automated summary reporting and outputs for downstream use

**Tradeoffs:**
- Initial setup complexity (multiple modules, OIDC wiring)
- Requires careful output management between modules
- Ephemeral infra means state is not persisted between runs (by design)

---

## 8. Final Summary

Project Aura_AI-driven-Under-utilized-Resource-Autoscaler is a modular, production-grade Terraform and CI/CD system for running LLM workloads on AWS EKS with just-in-time GPU autoscaling. It automates the full lifecycle, ensures security and cost efficiency, and exposes all key outputs for downstream automation.

**In short:**
> This repo lets you spin up, run, and tear down GPU-powered EKS clusters for AI jobs on AWS, all automated and secure, with zero idle cost.

---

## Author

**Eric Chiu**  
Portfolio: [Deploy on Demand](https://github.com/iEric0228/cloud-resume)  
LinkedIn: [Eric Chiu](https://www.linkedin.com/in/eric-chiu-a610553a3/)  
GitHub: [@iEric0228](https://github.com/iEric0228)  
Email: [ericchiu0228@gmail.com](mailto:ericchiu0228@gmail.com)
