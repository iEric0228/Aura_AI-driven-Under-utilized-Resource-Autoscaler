#!/bin/bash
# Bootstrap script to create S3 bucket and DynamoDB table for Terraform remote state
# Run this ONCE before using Terraform with remote backend
#
# Usage:
#   ./scripts/bootstrap-backend.sh

set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME="aura-terraform-state-${ACCOUNT_ID}"
DYNAMODB_TABLE="aura-terraform-locks"

echo "=== Terraform Backend Bootstrap ==="
echo "Region: $AWS_REGION"
echo "Account ID: $ACCOUNT_ID"
echo "S3 Bucket: $BUCKET_NAME"
echo "DynamoDB Table: $DYNAMODB_TABLE"
echo ""

# Create S3 bucket for state storage
echo ">>> Creating S3 bucket for Terraform state..."
if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
  echo "✅ S3 bucket already exists: $BUCKET_NAME"
else
  aws s3api create-bucket \
    --bucket "$BUCKET_NAME" \
    --region "$AWS_REGION" \
    --create-bucket-configuration LocationConstraint="$AWS_REGION" 2>/dev/null || \
  aws s3api create-bucket \
    --bucket "$BUCKET_NAME" \
    --region "$AWS_REGION"
  
  echo "✅ S3 bucket created: $BUCKET_NAME"
  
  # Enable versioning
  aws s3api put-bucket-versioning \
    --bucket "$BUCKET_NAME" \
    --versioning-configuration Status=Enabled
  echo "✅ Versioning enabled on S3 bucket"
  
  # Enable encryption
  aws s3api put-bucket-encryption \
    --bucket "$BUCKET_NAME" \
    --server-side-encryption-configuration '{
      "Rules": [{
        "ApplyServerSideEncryptionByDefault": {
          "SSEAlgorithm": "AES256"
        },
        "BucketKeyEnabled": true
      }]
    }'
  echo "✅ Server-side encryption enabled on S3 bucket"
  
  # Block public access
  aws s3api put-public-access-block \
    --bucket "$BUCKET_NAME" \
    --public-access-block-configuration '{
      "BlockPublicAcls": true,
      "IgnorePublicAcls": true,
      "BlockPublicPolicy": true,
      "RestrictPublicBuckets": true
    }'
  echo "✅ Public access blocked on S3 bucket"
fi

# Create DynamoDB table for state locking
echo ""
echo ">>> Creating DynamoDB table for state locking..."
if aws dynamodb describe-table --table-name "$DYNAMODB_TABLE" --region "$AWS_REGION" 2>/dev/null; then
  echo "✅ DynamoDB table already exists: $DYNAMODB_TABLE"
else
  aws dynamodb create-table \
    --table-name "$DYNAMODB_TABLE" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$AWS_REGION"
  
  echo "✅ DynamoDB table created: $DYNAMODB_TABLE"
  
  # Wait for table to be active
  echo ">>> Waiting for DynamoDB table to be active..."
  aws dynamodb wait table-exists --table-name "$DYNAMODB_TABLE" --region "$AWS_REGION"
  echo "✅ DynamoDB table is active"
fi

echo ""
echo "=== Bootstrap Complete ==="
echo ""
echo "Your Terraform backend is ready. Update your main.tf with:"
echo ""
echo '  backend "s3" {'
echo "    bucket         = \"$BUCKET_NAME\""
echo '    key            = "dev/terraform.tfstate"'
echo "    region         = \"$AWS_REGION\""
echo '    encrypt        = true'
echo "    dynamodb_table = \"$DYNAMODB_TABLE\""
echo '  }'
echo ""
echo "Then run:"
echo "  cd terraform/environments/dev"
echo "  terraform init -migrate-state  # To migrate existing local state to S3"
echo ""
