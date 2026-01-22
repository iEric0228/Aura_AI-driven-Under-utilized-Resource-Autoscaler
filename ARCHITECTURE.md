# Architecture Deep Dive: Aura AI-Driven Under-utilized Resource Autoscaler

## 1. Big Picture

**Project Type:** Infrastructure-as-Code (IaC) automation system for ephemeral Kubernetes clusters

**Problem Solved:**
This project solves the challenge of running cost-efficient, on-demand AI/ML workloads (particularly LLM jobs) on AWS EKS. Instead of maintaining expensive, always-on GPU clusters, it provides a fully automated system that:
- Spins up Kubernetes clusters on-demand
- Automatically provisions compute nodes when workloads need them (via Karpenter)
- Runs jobs and collects results
- Tears down everything when done (zero idle cost)

**Target Use Case:** Ephemeral AI workloads that need GPU resources but don't require persistent infrastructure.

---

## 2. Core Architecture

### Architecture Pattern: **Modular Infrastructure-as-Code with CI/CD Orchestration**

The system follows a **layered, modular architecture** with clear separation of concerns:

```
┌─────────────────────────────────────────────────────────────┐
│                    CI/CD Layer (GitHub Actions)              │
│  Orchestrates: Deploy → Run → Collect → Destroy              │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│              Infrastructure Layer (Terraform)                 │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐    │
│  │   VPC    │→ │   EKS    │→ │   IAM    │→ │  OIDC   │    │
│  │  Module  │  │  Module  │  │  Module  │  │ Provider│    │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘    │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│            Kubernetes Layer (EKS + Karpenter)                │
│  ┌──────────────┐         ┌──────────────┐                  │
│  │   EKS        │         │  Karpenter   │                  │
│  │  Cluster     │◄────────│  Controller │                  │
│  └──────────────┘         └──────────────┘                  │
│       │                          │                          │
│       └──────────┬───────────────┘                          │
│                  ▼                                            │
│         ┌─────────────────┐                                 │
│         │  EC2 Nodes       │                                 │
│         │  (Auto-provision)│                                 │
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
│   └── app-job.yml                 # Example Kubernetes Job
├── .github/
│   └── workflows/
│       └── cd-cd.yml               # CI/CD pipeline
└── env.example                     # Environment variables template
```

---

## 3. Key Components

### 3.1 VPC Module (`terraform/modules/VPC/`)

**Purpose:** Creates the network foundation for the EKS cluster

**What it creates:**
- VPC with DNS support
- Public subnets (2) with Internet Gateway
- Private subnets (2) with NAT Gateway
- Route tables and associations
- **Critical:** Tags subnets with `karpenter.sh/discovery` for Karpenter discovery

**Key Design Decision:** Both public and private subnets are tagged for Karpenter, allowing flexibility in node placement.

**Dependencies:** None (foundational module)

---

### 3.2 IAM_EKS Module (`terraform/modules/IAM_EKS/`)

**Purpose:** Creates IAM roles for the EKS cluster and worker nodes

**What it creates:**
- `aws_iam_role.eks_cluster_role` - Role for EKS control plane
- `aws_iam_role.eks_node_role` - Role for worker nodes
- `aws_iam_instance_profile.eks_node_instance_profile` - Instance profile for nodes (required by Karpenter)

**Key Design Decision:** Separate roles for cluster vs nodes follows AWS best practices and least-privilege.

**Dependencies:** None (but requires assume role policy document)

---

### 3.3 EKS Module (`terraform/modules/EKS/`)

**Purpose:** Creates and configures the Kubernetes cluster

**What it creates:**
- EKS cluster (v1.31) with API-only authentication
- EKS access entry + policy for admin access
- EKS node group (baseline: 1-2 t3.medium nodes)
- **Critical:** Tags cluster security group with `karpenter.sh/discovery`
- Attaches IAM policies to cluster and node roles

**Key Design Decision:** 
- Uses `authentication_mode = "API"` (modern EKS access control)
- Creates minimal baseline node group (Karpenter handles scaling)
- Tags security group so Karpenter can discover it

**Dependencies:** 
- VPC module (subnet IDs)
- IAM_EKS module (role ARNs)

---

### 3.4 IAM Module (`terraform/modules/IAM/`)

**Purpose:** Creates IAM role for Karpenter controller with IRSA (IAM Roles for Service Accounts)

**What it creates:**
- IAM role with OIDC trust policy (allows Karpenter service account to assume role)
- Inline IAM policy (from JSON file) granting EC2, IAM, Launch Template permissions
- Policy attachment

**Key Design Decision:** Uses IRSA for secure, zero-secret authentication between Karpenter pods and AWS APIs.

**Dependencies:**
- EKS module (OIDC provider URL/ARN)
- External script (OIDC thumbprint calculation)

---

### 3.5 OIDC Provider (`terraform/environments/dev/main.tf`)

**Purpose:** Enables IRSA by creating an OIDC identity provider

**What it creates:**
- `aws_iam_openid_connect_provider` linked to EKS cluster's OIDC issuer
- Uses Python script to fetch SSL certificate thumbprint

**Key Design Decision:** External script with error handling ensures robust thumbprint calculation.

**Dependencies:**
- EKS module (OIDC issuer URL)
- Python script (`get-oidc-thumbprint.py`)

---

### 3.6 Karpenter Provisioner (`Karpenter/main.yml`)

**Purpose:** Defines how Karpenter should provision nodes

**Configuration:**
- **Instance Types:** t3.medium, t3.large, t3.xlarge
- **Capacity Type:** On-demand (avoids Spot service-linked role requirement)
- **Discovery:** Uses tags `karpenter.sh/discovery: aura-eks-dev`
- **TTL:** 60 seconds after nodes become empty (aggressive cost optimization)

**Key Design Decision:** On-demand instances avoid Spot permission complexity while maintaining cost control via aggressive scale-down.

---

### 3.7 CI/CD Workflow (`.github/workflows/cd-cd.yml`)

**Purpose:** Fully automated deployment and teardown pipeline

**Workflow Steps:**

```
1. Checkout Code
2. Configure AWS Credentials (OIDC-based, no secrets!)
3. Terraform Init/Plan/Apply
   └─ Creates: VPC → EKS → IAM → OIDC Provider
4. Get Terraform Outputs (cluster name, endpoint, role ARNs)
5. Configure kubectl (connect to EKS cluster)
6. Deploy Karpenter (Helm chart)
7. Wait for Karpenter Ready (with health checks)
8. Apply Karpenter Provisioner (with webhook workaround)
9. Deploy Application Job
10. Wait for Job Completion (if deploy-and-destroy)
11. Collect Comprehensive Metrics
12. Terraform Destroy (if not 'deploy' only)
13. Generate & Upload Summary Report
```

**Key Features:**
- **OIDC Authentication:** No AWS credentials stored in GitHub
- **Comprehensive Reporting:** Collects nodes, pods, events, logs
- **Error Handling:** Detailed logging and debugging output
- **Flexible Actions:** deploy, deploy-and-destroy, destroy

---

## 4. Data Flow & Communication

### 4.1 Infrastructure Provisioning Flow

```
┌──────────────────────────────────────────────────────────────┐
│ Terraform Apply (terraform/environments/dev/main.tf)         │
└──────────────────────────────────────────────────────────────┘
                            │
        ┌───────────────────┼───────────────────┐
        │                   │                   │
        ▼                   ▼                   ▼
┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│ VPC Module   │    │ IAM_EKS     │    │ (standalone) │
│ Creates:     │    │ Creates:    │    │              │
│ - VPC        │    │ - Cluster   │    │              │
│ - Subnets    │    │   Role      │    │              │
│ - NAT GW     │    │ - Node Role │    │              │
│ - Routes     │    │ - Instance  │    │              │
│              │    │   Profile   │    │              │
└──────┬───────┘    └──────┬──────┘    └──────────────┘
       │                   │
       │                   │ (subnet_ids, role_arns)
       │                   │
       └───────────┬───────┘
                   │
                   ▼
          ┌─────────────────┐
          │   EKS Module    │
          │ Creates:        │
          │ - EKS Cluster   │
          │ - Node Group    │
          │ - Access Entry  │
          │ - Security Group│
          │   (tagged)      │
          └────────┬────────┘
                   │
                   │ (oidc_issuer_url)
                   │
                   ▼
          ┌─────────────────┐
          │ OIDC Provider   │
          │ (uses Python    │
          │  script for     │
          │  thumbprint)    │
          └────────┬────────┘
                   │
                   │ (oidc_provider_arn, url)
                   │
                   ▼
          ┌─────────────────┐
          │   IAM Module    │
          │ Creates:        │
          │ - Karpenter     │
          │   Controller    │
          │   Role (IRSA)   │
          │ - Inline Policy │
          └─────────────────┘
```

### 4.2 Karpenter Autoscaling Flow

```
┌──────────────────────────────────────────────────────────────┐
│ 1. User/CI/CD Creates Kubernetes Pod/Job                    │
│    kubectl apply -f app-job.yml                             │
└──────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. Kubernetes Scheduler: Pod Status = Pending               │
│    (No nodes have capacity)                                 │
└──────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. Karpenter Controller Detects Pending Pod                 │
│    - Watches Kubernetes API                                 │
│    - Evaluates Provisioner requirements                     │
│    - Calculates: "Need 1 node with 3 CPU, 3Gi RAM"         │
└──────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. Karpenter Discovers Resources                            │
│    - Queries AWS EC2: Subnets with tag                      │
│      karpenter.sh/discovery: aura-eks-dev                  │
│    - Queries AWS EC2: Security Groups with same tag         │
│    - Selects instance type: t3.xlarge (fits requirements)    │
└──────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. Karpenter Creates Launch Template                        │
│    - Uses node instance profile (from Terraform)           │
│    - Configures user-data for EKS node registration        │
│    - Tags instance with Karpenter labels                    │
└──────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────┐
│ 6. Karpenter Launches EC2 Instance                         │
│    - Calls EC2 RunInstances API                             │
│    - Instance boots in private subnet                      │
│    - Node registers with EKS cluster                       │
└──────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────┐
│ 7. Kubernetes Scheduler Places Pod on New Node              │
│    - Node becomes Ready                                     │
│    - Pod status: Pending → Running                          │
└──────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────┐
│ 8. After Job Completes + 60s Empty                          │
│    Karpenter Terminates Empty Node                          │
│    (ttlSecondsAfterEmpty: 60)                               │
└──────────────────────────────────────────────────────────────┘
```

### 4.3 CI/CD Execution Flow

```
GitHub Actions Workflow Trigger
    │
    ├─→ Checkout Code
    ├─→ AWS OIDC Auth (assume role via GitHub identity)
    ├─→ Terraform Init
    ├─→ Terraform Plan
    ├─→ Terraform Apply
    │   └─→ Creates all infrastructure (VPC → EKS → IAM → OIDC)
    │
    ├─→ Get Terraform Outputs (JSON)
    ├─→ Configure kubectl (aws eks update-kubeconfig)
    │
    ├─→ Deploy Karpenter (Helm)
    │   └─→ Sets: clusterName, clusterEndpoint, role ARN, instance profile
    │
    ├─→ Wait for Karpenter Ready (health checks)
    ├─→ Apply Provisioner (with webhook workaround)
    │
    ├─→ Deploy App Job (kubectl apply)
    │   └─→ Karpenter provisions node automatically
    │
    ├─→ Wait for Job Completion (if deploy-and-destroy)
    │
    ├─→ Collect Metrics
    │   ├─→ Nodes (JSON)
    │   ├─→ Pods (JSON)
    │   ├─→ Events (text)
    │   ├─→ Karpenter logs
    │   └─→ Job logs
    │
    ├─→ Generate Summary Report (Markdown)
    ├─→ Upload Artifacts
    │
    └─→ Terraform Destroy (if not 'deploy' only)
        └─→ Tears down all resources
```

---

## 5. Tech Stack & Dependencies

### Infrastructure Layer

| Technology | Purpose | Why It's Used |
|------------|---------|---------------|
| **Terraform** | Infrastructure provisioning | Declarative IaC, state management, module reusability |
| **AWS EKS** | Kubernetes orchestration | Managed Kubernetes, AWS integration, scalability |
| **AWS VPC** | Network isolation | Security, subnet management, NAT gateway for private nodes |
| **AWS IAM** | Access control | Fine-grained permissions, IRSA for pod-to-AWS communication |
| **AWS EC2** | Compute instances | On-demand node provisioning via Karpenter |

### Kubernetes Layer

| Technology | Purpose | Why It's Used |
|------------|---------|---------------|
| **Karpenter** | Node autoscaler | Fast provisioning (<2min), cost-optimized, AWS-native |
| **Kubernetes Jobs** | Workload execution | Batch processing, one-time tasks, completion tracking |
| **Helm** | Package management | Karpenter installation, version pinning, configuration |

### CI/CD Layer

| Technology | Purpose | Why It's Used |
|------------|---------|---------------|
| **GitHub Actions** | Pipeline orchestration | Native GitHub integration, OIDC support, artifact storage |
| **AWS OIDC** | Authentication | No secrets, secure role assumption, audit trail |
| **kubectl** | Cluster management | Kubernetes API access, resource deployment |

### Supporting Tools

| Technology | Purpose |
|------------|---------|
| **Python 3** | OIDC thumbprint calculation |
| **jq** | JSON parsing in CI/CD |
| **bash** | Scripting and automation |

---

## 6. Execution Flow Example

### Scenario: Running an AI/ML Job via CI/CD

**Step-by-Step Walkthrough:**

```
1. Developer triggers GitHub Actions workflow
   Input: action="deploy-and-destroy", job_name="example-job"
   
2. GitHub Actions authenticates to AWS
   - Uses OIDC token (no AWS credentials stored)
   - Assumes role: arn:aws:iam::125156866057:role/github-OICD
   
3. Terraform provisions infrastructure (~5-8 minutes)
   ├─ VPC created (10.0.0.0/16)
   ├─ Subnets created (public: 10.0.1.0/24, 10.0.2.0/24)
   │                    (private: 10.0.3.0/24, 10.0.4.0/24)
   ├─ NAT Gateway created (for private subnet internet access)
   ├─ IAM roles created (cluster, node, Karpenter)
   ├─ EKS cluster created (aura-eks-dev)
   ├─ Baseline node group created (1x t3.medium)
   ├─ OIDC provider created (for IRSA)
   └─ Security group tagged (karpenter.sh/discovery: aura-eks-dev)
   
4. Terraform outputs captured
   - cluster_name: "aura-eks-dev"
   - cluster_endpoint: "https://..."
   - karpenter_controller_role_arn: "arn:aws:iam::..."
   - node_instance_profile_name: "aura-eks-node-role-instance-profile"
   
5. kubectl configured
   aws eks update-kubeconfig --name aura-eks-dev
   
6. Karpenter deployed via Helm (~2 minutes)
   - Helm installs Karpenter chart (v0.16.3)
   - Controller pod starts
   - Webhook pod starts
   - Service account annotated with IAM role ARN
   
7. Karpenter Provisioner applied
   - CRD defines: instance types, capacity type, discovery tags
   - Webhooks temporarily disabled (v0.16.3 TLS workaround)
   
8. Application Job deployed
   kubectl apply -f Karpenter/app-job.yml
   - Job requests: 1 CPU, 1Gi memory
   - Pod status: Pending (baseline node may have capacity)
   
9. Karpenter evaluates provisioning needs
   - If baseline node has capacity: Pod schedules immediately
   - If not: Karpenter provisions new node
     ├─ Discovers subnets (tag: karpenter.sh/discovery)
     ├─ Discovers security group (tag: karpenter.sh/discovery)
     ├─ Selects instance type (t3.medium fits 1 CPU, 1Gi)
     ├─ Creates launch template
     ├─ Launches EC2 instance (~1-2 minutes)
     └─ Node registers with EKS cluster
   
10. Job executes
    - Pod runs on provisioned node
    - Job completes (calculates pi to 2000 digits)
    - Logs collected
    
11. Scale-down (if node empty for 60s)
    - Karpenter detects empty node
    - Terminates EC2 instance
    - Node removed from cluster
    
12. Summary report generated
    - Node counts, pod status, resource utilization
    - Karpenter events, job logs
    - Errors/warnings
    
13. Terraform destroy (if deploy-and-destroy)
    - All resources deleted
    - Zero cost after completion
```

---

## 7. Strengths & Tradeoffs

### ✅ Strengths

1. **Modularity & Reusability**
   - Terraform modules are self-contained and reusable
   - Easy to add new environments (prod, staging) by copying `dev/`
   - Clear separation: VPC, EKS, IAM responsibilities

2. **Security Best Practices**
   - OIDC-based authentication (no secrets in GitHub)
   - IRSA for pod-to-AWS communication (no IAM keys)
   - Least-privilege IAM policies
   - Private subnets for worker nodes

3. **Cost Optimization**
   - Ephemeral infrastructure (destroyed after use)
   - Aggressive scale-down (60s empty TTL)
   - Minimal baseline nodes (Karpenter handles scaling)
   - On-demand instances (predictable costs)

4. **Observability**
   - Comprehensive CI/CD summary reports
   - Detailed logging and event collection
   - Artifact storage for debugging

5. **Automation**
   - Fully automated lifecycle (deploy → run → destroy)
   - No manual intervention required
   - Reproducible deployments

6. **Error Handling**
   - Python script with try/except blocks
   - Health checks for Karpenter readiness
   - Detailed error messages in logs

### ⚠️ Tradeoffs & Limitations

1. **Initial Setup Complexity**
   - Multiple Terraform modules to understand
   - OIDC provider setup requires thumbprint calculation
   - Karpenter webhook workaround needed (v0.16.3 limitation)

2. **State Management**
   - Ephemeral by design (state destroyed after run)
   - Not suitable for persistent workloads
   - Requires re-provisioning for each run

3. **Cold Start Time**
   - Infrastructure provisioning: ~5-8 minutes
   - Node provisioning: ~1-2 minutes
   - Total time to first pod: ~7-10 minutes

4. **Instance Type Limitations**
   - Currently limited to t3 family (medium, large, xlarge)
   - No GPU instance types configured (despite project name)
   - On-demand only (no Spot for cost savings)

5. **Single Region/AZ**
   - Hardcoded to us-east-1
   - Limited to 2 availability zones
   - No multi-region support

6. **Karpenter Version**
   - Using v0.16.3 (older version)
   - Webhook TLS issues require workaround
   - Missing newer Karpenter features

### 🔧 Areas for Improvement

1. **Add GPU Support**
   - Add GPU instance types (g4dn, g5) to Provisioner
   - Configure NVIDIA device plugin
   - Update documentation

2. **Spot Instance Support**
   - Add Spot capacity type option
   - Create EC2 Spot service-linked role
   - Configure interruption handling

3. **Multi-Environment Support**
   - Parameterize region/AZ
   - Environment-specific variable files
   - Separate Terraform workspaces

4. **Upgrade Karpenter**
   - Migrate to newer version (v1.x)
   - Remove webhook workaround
   - Leverage new features

5. **Enhanced Monitoring**
   - CloudWatch integration
   - Prometheus metrics export
   - Cost tracking per run

---

## 8. Final Summary

**In 2-3 sentences:**

This is a **fully automated, ephemeral Kubernetes infrastructure system** that uses Terraform to provision AWS EKS clusters with Karpenter autoscaling, runs AI/ML workloads on-demand, and tears everything down when done—achieving **zero idle cost**. The architecture is **modular and secure** (OIDC authentication, IRSA for pods, least-privilege IAM), with a **comprehensive CI/CD pipeline** that handles the entire lifecycle from infrastructure creation to job execution to resource cleanup, complete with detailed reporting.

**Key Value Proposition:**
> Spin up a production-grade Kubernetes cluster, run your AI workload, get results, and pay only for what you use—all with a single GitHub Actions workflow trigger.

---

## Appendix: Key Files Reference

| File | Purpose |
|------|---------|
| `terraform/environments/dev/main.tf` | Root module - wires all components together |
| `terraform/modules/VPC/main.tf` | Network infrastructure (VPC, subnets, NAT) |
| `terraform/modules/EKS/main.tf` | Kubernetes cluster + node group + access control |
| `terraform/modules/IAM/main.tf` | Karpenter controller IAM role (IRSA) |
| `terraform/modules/IAM_EKS/main.tf` | EKS cluster/node IAM roles |
| `Karpenter/main.yml` | Karpenter Provisioner CRD (defines scaling behavior) |
| `Karpenter/app-job.yml` | Example Kubernetes Job manifest |
| `.github/workflows/cd-cd.yml` | CI/CD pipeline (deploy → run → destroy) |
| `terraform/environments/dev/get-oidc-thumbprint.py` | Helper script for OIDC provider setup |

---

*Document generated: 2026-01-21*  
*Architecture version: 1.0*
