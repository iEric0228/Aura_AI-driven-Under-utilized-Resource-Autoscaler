#!/bin/bash
# Local test script for Terraform and tf-outputs.json validation
# Run this before pushing to CI/CD to catch errors early.
#
# Usage:
#   ./local-test.sh                    # Interactive mode (prompts for apply/destroy)
#   ./local-test.sh --auto-destroy     # Apply and always destroy after test
#   ./local-test.sh --plan-only        # Only run init, validate, plan (no apply)
#   ./local-test.sh --destroy-only     # Only run destroy (cleanup orphaned resources)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$SCRIPT_DIR/../terraform/environments/dev"
REQUIRED_KEYS=(cluster_name cluster_endpoint karpenter_controller_role_arn node_instance_profile_name)

# Parse arguments
AUTO_DESTROY=false
PLAN_ONLY=false
DESTROY_ONLY=false
APPLIED=false

for arg in "$@"; do
  case $arg in
    --auto-destroy)
      AUTO_DESTROY=true
      shift
      ;;
    --plan-only)
      PLAN_ONLY=true
      shift
      ;;
    --destroy-only)
      DESTROY_ONLY=true
      shift
      ;;
    *)
      ;;
  esac
done

# Cleanup function to ensure destroy runs if apply was done
cleanup() {
  if [ "$APPLIED" = true ] && [ "$AUTO_DESTROY" = true ]; then
    echo ""
    echo ">>> Cleanup: Running terraform destroy (auto-destroy enabled)..."
    cd "$TF_DIR"
    terraform destroy -auto-approve || echo "Warning: Terraform destroy encountered errors"
    echo "✅ Terraform destroy complete."
  fi
}

# Set trap to run cleanup on exit (success or failure)
trap cleanup EXIT

echo "=== Local Terraform Test Script ==="
echo "Working directory: $TF_DIR"
echo "Options: AUTO_DESTROY=$AUTO_DESTROY, PLAN_ONLY=$PLAN_ONLY, DESTROY_ONLY=$DESTROY_ONLY"
cd "$TF_DIR"

# 1. Handle destroy-only mode
if [ "$DESTROY_ONLY" = true ]; then
  echo ""
  echo ">>> Running terraform init..."
  terraform init
  echo ""
  echo ">>> Running terraform destroy (destroy-only mode)..."
  terraform destroy -auto-approve
  echo "✅ Terraform destroy complete."
  exit 0
fi

# 2. Terraform Init
echo ""
echo ">>> Running terraform init..."
terraform init

# 3. Terraform Validate
echo ""
echo ">>> Running terraform validate..."
terraform validate

# 4. Terraform Plan
echo ""
echo ">>> Running terraform plan..."
terraform plan -out=tfplan

# 5. Exit early if plan-only mode
if [ "$PLAN_ONLY" = true ]; then
  echo ""
  echo "✅ Plan-only mode complete. Skipping apply."
  exit 0
fi

# 6. Terraform Apply (auto or interactive)
if [ "$AUTO_DESTROY" = true ]; then
  echo ""
  echo ">>> Running terraform apply (auto-destroy mode)..."
  terraform apply -auto-approve
  APPLIED=true
else
  read -p "Apply Terraform changes? (y/N): " APPLY_CONFIRM
  if [[ "$APPLY_CONFIRM" =~ ^[Yy]$ ]]; then
    echo ""
    echo ">>> Running terraform apply..."
    terraform apply -auto-approve
    APPLIED=true
  else
    echo ""
    echo "Skipping apply. Only init, validate, and plan were run."
    exit 0
  fi
fi

# 7. Generate tf-outputs.json
echo ""
echo ">>> Generating tf-outputs.json..."
terraform output -json > tf-outputs.json

# 8. Validate tf-outputs.json
echo ""
echo ">>> Validating tf-outputs.json..."
if [ ! -s tf-outputs.json ]; then
  echo "ERROR: tf-outputs.json is missing or empty!"
  exit 1
fi

for key in "${REQUIRED_KEYS[@]}"; do
  value="$(jq -r --arg k "$key" '.[$k].value // empty' tf-outputs.json)"
  if [ -z "$value" ] || [ "$value" = "null" ]; then
    echo "ERROR: Missing or empty Terraform output: $key"
    echo "Available keys:"
    jq -r 'keys[]' tf-outputs.json || true
    exit 1
  fi
done

echo ""
echo "✅ tf-outputs.json is valid. All required keys present."
echo ""
cat tf-outputs.json

# 9. Validate EKS cluster connectivity and Karpenter
echo ""
echo ">>> Validating EKS cluster connectivity..."
CLUSTER_NAME=$(jq -r '.cluster_name.value' tf-outputs.json)
AWS_REGION="${AWS_REGION:-us-east-1}"

# Check if AWS credentials are configured
if ! aws sts get-caller-identity &>/dev/null; then
  echo "ERROR: AWS credentials are not configured or invalid."
  echo "Please configure AWS credentials with:"
  echo "  aws configure"
  echo "  or set AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN"
  exit 1
fi

echo "AWS identity: $(aws sts get-caller-identity --query 'Arn' --output text)"

aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME" || {
  echo "ERROR: Failed to configure kubectl for cluster $CLUSTER_NAME"
  exit 1
}

# Verify kubectl can authenticate
echo ""
echo ">>> Verifying kubectl authentication..."
if ! kubectl auth can-i get nodes &>/dev/null; then
  echo "WARNING: kubectl cannot authenticate to the cluster."
  echo "This might be because:"
  echo "  1. Your AWS IAM user/role doesn't have EKS access"
  echo "  2. The cluster's aws-auth ConfigMap doesn't include your IAM identity"
  echo ""
  echo "To fix this, you need to add your IAM user/role to the cluster's aws-auth ConfigMap."
  echo "See: https://docs.aws.amazon.com/eks/latest/userguide/add-user-role.html"
  echo ""
  echo "Skipping kubectl validation steps..."
  SKIP_KUBECTL=true
else
  SKIP_KUBECTL=false
  echo "✅ kubectl authentication successful"
fi

if [ "$SKIP_KUBECTL" = false ]; then
  echo ""
  echo ">>> Checking cluster nodes..."
  kubectl get nodes -o wide || echo "Warning: Could not get nodes"

  echo ""
  echo ">>> Checking all pods..."
  kubectl get pods -A || echo "Warning: Could not get pods"
fi

# 10. Deploy and validate Karpenter (optional, if helm is available)
if [ "$SKIP_KUBECTL" = false ] && command -v helm &> /dev/null; then
  echo ""
  echo ">>> Checking if Karpenter is installed..."
  
  # Get required values from Terraform outputs
  CLUSTER_ENDPOINT=$(jq -r '.cluster_endpoint.value' tf-outputs.json)
  KARPENTER_ROLE_ARN=$(jq -r '.karpenter_controller_role_arn.value' tf-outputs.json)
  INSTANCE_PROFILE=$(jq -r '.node_instance_profile_name.value' tf-outputs.json)
  
  if helm list -n karpenter 2>/dev/null | grep -q karpenter; then
    echo "✅ Karpenter is installed"
    kubectl get pods -n karpenter
    
    # Check if Karpenter is actually running (not just installed)
    KARPENTER_PHASE=$(kubectl get pods -n karpenter -l app.kubernetes.io/name=karpenter -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
    if [ "$KARPENTER_PHASE" != "Running" ]; then
      echo ""
      echo "⚠️ Karpenter pods are not fully ready (phase: $KARPENTER_PHASE). Checking logs..."
      kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter --tail=20 2>/dev/null || true
      
      echo ""
      read -p "Karpenter may need reconfiguration. Upgrade Karpenter with correct settings? (y/N): " UPGRADE_KARPENTER
      if [[ "$UPGRADE_KARPENTER" =~ ^[Yy]$ ]]; then
        echo ""
        echo ">>> Upgrading Karpenter v0.37.0 with correct settings..."
        helm upgrade karpenter oci://public.ecr.aws/karpenter/karpenter \
          --namespace karpenter \
          --version 0.37.0 \
          --set "settings.clusterName=$CLUSTER_NAME" \
          --set "settings.clusterEndpoint=$CLUSTER_ENDPOINT" \
          --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$KARPENTER_ROLE_ARN" \
          --set "settings.interruptionQueue=" \
          --set replicas=1 \
          --set controller.resources.requests.cpu=200m \
          --set controller.resources.requests.memory=256Mi \
          --set controller.resources.limits.cpu=500m \
          --set controller.resources.limits.memory=512Mi \
          --wait --timeout 3m
        
        echo ""
        echo ">>> Waiting for Karpenter to be ready (up to 60s)..."
        sleep 10
        for i in {1..5}; do
          # v0.27.5 has a single container per pod
          READY=$(kubectl get pods -n karpenter -l app.kubernetes.io/name=karpenter -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
          if [ "$READY" = "Running" ]; then
            echo "✅ Karpenter is now ready!"
            break
          fi
          echo "  Waiting... ($i/5)"
          kubectl get pods -n karpenter
          sleep 10
        done
      fi
    fi
    
    kubectl get nodepools 2>/dev/null || echo "No NodePools found yet"
    kubectl get ec2nodeclasses 2>/dev/null || echo "No EC2NodeClasses found yet"
  else
    echo "⚠️ Karpenter is not installed."
    read -p "Install Karpenter now? (y/N): " INSTALL_KARPENTER
    if [[ "$INSTALL_KARPENTER" =~ ^[Yy]$ ]]; then
      echo ""
      echo ">>> Installing Karpenter v0.37.0 with settings:"
      echo "    Cluster Name: $CLUSTER_NAME"
      echo "    Cluster Endpoint: $CLUSTER_ENDPOINT"
      echo "    IAM Role ARN: $KARPENTER_ROLE_ARN"
      
      # Use OCI registry (charts.karpenter.sh is deprecated)
      helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
        --namespace karpenter --create-namespace \
        --version 0.37.0 \
        --set "settings.clusterName=$CLUSTER_NAME" \
        --set "settings.clusterEndpoint=$CLUSTER_ENDPOINT" \
        --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$KARPENTER_ROLE_ARN" \
        --set "settings.interruptionQueue=" \
        --set replicas=1 \
        --set controller.resources.requests.cpu=200m \
        --set controller.resources.requests.memory=256Mi \
        --set controller.resources.limits.cpu=500m \
        --set controller.resources.limits.memory=512Mi \
        --wait --timeout 3m
      
      echo ""
      echo ">>> Waiting for Karpenter to be ready (up to 90s)..."
      # --wait flag should handle this, just verify
      for i in {1..6}; do
        READY=$(kubectl get pods -n karpenter -l app.kubernetes.io/name=karpenter -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
        if [ "$READY" = "Running" ]; then
          echo "✅ Karpenter is ready!"
          break
        fi
        echo "  Waiting... ($i/6)"
        kubectl get pods -n karpenter
        sleep 15
      done
      
      # Apply the Karpenter NodePool configuration
      echo ""
      echo ">>> Applying Karpenter NodePool configuration..."
      KARPENTER_DIR="$SCRIPT_DIR/../Karpenter"
      if [ -f "$KARPENTER_DIR/main.yml" ]; then
        kubectl apply -f "$KARPENTER_DIR/main.yml"
        echo "✅ Karpenter NodePools and EC2NodeClasses applied"
        kubectl get nodepools
        kubectl get ec2nodeclasses
      else
        echo "⚠️ Karpenter config file not found at $KARPENTER_DIR/main.yml"
      fi
    else
      echo "Skipping Karpenter installation."
    fi
  fi
else
  if [ "$SKIP_KUBECTL" = true ]; then
    echo ""
    echo "⚠️ Skipping Karpenter check (kubectl authentication failed)"
  else
    echo ""
    echo "⚠️ Helm not found, skipping Karpenter check"
  fi
fi

# 11. Run a simple non-GPU test job to validate autoscaling (optional)
if [ "$SKIP_KUBECTL" = false ]; then
  read -p "Deploy a simple CPU test job to validate Karpenter autoscaling? (y/N): " TEST_JOB_CONFIRM
  if [[ "$TEST_JOB_CONFIRM" =~ ^[Yy]$ ]]; then
    echo ""
    echo ">>> Deploying simple CPU test job..."
    cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: cpu-test-job
  namespace: default
spec:
  template:
    spec:
      containers:
      - name: busybox
        image: busybox
        command: ["sh", "-c", "echo 'CPU test started'; sleep 30; echo 'CPU test successful!'"]
        resources:
          requests:
            cpu: "500m"
            memory: "256Mi"
      restartPolicy: Never
  backoffLimit: 1
EOF

  echo ""
  echo ">>> Waiting for CPU test job to complete (timeout: 120s)..."
  if kubectl wait --for=condition=complete --timeout=120s job/cpu-test-job -n default 2>/dev/null; then
    echo "✅ CPU test job completed successfully!"
    kubectl logs job/cpu-test-job -n default
  else
    echo "⚠️ CPU test job did not complete within timeout"
    kubectl describe job/cpu-test-job -n default
    kubectl get pods -n default -l job-name=cpu-test-job -o wide
  fi

  echo ""
  echo ">>> Cleaning up CPU test job..."
  kubectl delete job cpu-test-job -n default --ignore-not-found
fi
else
  echo ""
  echo "⚠️ Skipping CPU test job deployment (kubectl authentication failed)"
fi

# 12. Summary
echo ""
echo "=========================================="
echo "📊 Infrastructure Validation Summary"
echo "=========================================="
echo "Cluster Name:    $CLUSTER_NAME"
echo "Cluster Endpoint: $(jq -r '.cluster_endpoint.value' tf-outputs.json)"
if [ "$SKIP_KUBECTL" = false ]; then
  echo "Nodes:"
  kubectl get nodes --no-headers 2>/dev/null | wc -l | xargs echo "  Total:" || echo "  Total: N/A"
  kubectl get nodes --no-headers 2>/dev/null | grep -c Ready | xargs echo "  Ready:" || echo "  Ready: N/A"
  echo "Karpenter Pods:"
  kubectl get pods -n karpenter --no-headers 2>/dev/null | wc -l | xargs echo "  Total:" || echo "  Total: N/A"
else
  echo "Nodes: N/A (kubectl auth failed)"
  echo "Karpenter Pods: N/A (kubectl auth failed)"
fi
echo "=========================================="

# 13. Terraform Destroy (auto or interactive)
if [ "$AUTO_DESTROY" = true ]; then
  echo ""
  echo ">>> Auto-destroy will run via cleanup trap on exit..."
else
  read -p "Destroy Terraform resources? (y/N): " DESTROY_CONFIRM
  if [[ "$DESTROY_CONFIRM" =~ ^[Yy]$ ]]; then
    echo ""
    echo ">>> Running terraform destroy..."
    terraform destroy -auto-approve
    echo "✅ Terraform destroy complete."
    APPLIED=false  # Prevent double-destroy in trap
  fi
fi

echo ""
echo "=== Local test complete ==="
