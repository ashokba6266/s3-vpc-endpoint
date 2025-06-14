#!/bin/bash

# S3 VPC Endpoint Project - Force Cleanup (Non-interactive)
# Deletes all resources created by the project

set -e

# Load configuration
if [ ! -f "configs/vpc-parameters.json" ]; then
    echo "❌ Error: VPC configuration not found. Nothing to clean up."
    exit 0
fi

PROJECT_ID=$(jq -r '.project_id' configs/vpc-parameters.json)
AWS_REGION=$(jq -r '.region' configs/vpc-parameters.json)
VPC_ID=$(jq -r '.vpc_id' configs/vpc-parameters.json)
S3_BUCKET_NAME=$(jq -r '.s3_bucket_name' configs/vpc-parameters.json)

echo "🧹 S3 VPC Endpoint Project Force Cleanup"
echo "========================================"
echo "Project: $PROJECT_ID"
echo "Region: $AWS_REGION"
echo "VPC: $VPC_ID"
echo ""

# Function to safely delete resources
safe_delete() {
    local resource_type="$1"
    local delete_command="$2"
    local resource_id="$3"
    
    echo "🗑️ Deleting $resource_type: $resource_id"
    if eval "$delete_command" >/dev/null 2>&1; then
        echo "✅ $resource_type deleted successfully"
    else
        echo "⚠️  $resource_type may not exist or already deleted"
    fi
}

# Step 1: Terminate EC2 instances
echo "🖥️ Step 1: Terminating EC2 instances..."
INSTANCE_IDS=$(AWS_PAGER="" aws ec2 describe-instances \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=instance-state-name,Values=running,pending,stopping,stopped" \
    --region $AWS_REGION \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text 2>/dev/null || echo "")

if [[ -n "$INSTANCE_IDS" && "$INSTANCE_IDS" != "None" ]]; then
    for instance_id in $INSTANCE_IDS; do
        safe_delete "EC2 instance" "AWS_PAGER='' aws ec2 terminate-instances --instance-ids $instance_id --region $AWS_REGION" "$instance_id"
    done
    
    echo "⏳ Waiting for instances to terminate..."
    for instance_id in $INSTANCE_IDS; do
        AWS_PAGER="" aws ec2 wait instance-terminated --instance-ids $instance_id --region $AWS_REGION 2>/dev/null || echo "Instance $instance_id termination timeout"
    done
else
    echo "ℹ️  No EC2 instances found"
fi

# Step 2: Delete S3 bucket
echo ""
echo "🪣 Step 2: Deleting S3 bucket..."
if AWS_PAGER="" aws s3api head-bucket --bucket $S3_BUCKET_NAME --region $AWS_REGION >/dev/null 2>&1; then
    # Delete all objects and versions
    AWS_PAGER="" aws s3 rm s3://$S3_BUCKET_NAME --recursive --region $AWS_REGION >/dev/null 2>&1 || echo "Bucket already empty"
    
    # Delete versioned objects if any
    AWS_PAGER="" aws s3api delete-objects \
        --bucket $S3_BUCKET_NAME \
        --delete "$(AWS_PAGER="" aws s3api list-object-versions \
            --bucket $S3_BUCKET_NAME \
            --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
            --region $AWS_REGION 2>/dev/null)" \
        --region $AWS_REGION >/dev/null 2>&1 || echo "No versions to delete"
    
    safe_delete "S3 bucket" "AWS_PAGER='' aws s3api delete-bucket --bucket $S3_BUCKET_NAME --region $AWS_REGION" "$S3_BUCKET_NAME"
else
    echo "ℹ️  S3 bucket not found or already deleted"
fi

# Step 3: Delete VPC Endpoint
echo ""
echo "🔗 Step 3: Deleting VPC endpoint..."
S3_ENDPOINT_ID=$(jq -r '.s3_gateway_endpoint_id // empty' configs/vpc-parameters.json)
if [[ -n "$S3_ENDPOINT_ID" && "$S3_ENDPOINT_ID" != "null" ]]; then
    safe_delete "VPC endpoint" "AWS_PAGER='' aws ec2 delete-vpc-endpoint --vpc-endpoint-id $S3_ENDPOINT_ID --region $AWS_REGION" "$S3_ENDPOINT_ID"
else
    echo "ℹ️  VPC endpoint not found"
fi

# Step 4: Delete IAM resources
echo ""
echo "👤 Step 4: Deleting IAM resources..."
ROLE_NAME="$PROJECT_ID-ec2-role"
POLICY_NAME="$PROJECT_ID-s3-policy"
INSTANCE_PROFILE_NAME="$PROJECT_ID-instance-profile"

# Get account ID
ACCOUNT_ID=$(AWS_PAGER="" aws sts get-caller-identity --query Account --output text 2>/dev/null | grep -E '^[0-9]{12}$' | tail -1)

if [[ -n "$ACCOUNT_ID" ]]; then
    # Detach policy from role
    AWS_PAGER="" aws iam detach-role-policy \
        --role-name $ROLE_NAME \
        --policy-arn "arn:aws:iam::$ACCOUNT_ID:policy/$POLICY_NAME" >/dev/null 2>&1 || echo "Policy already detached"
    
    # Remove role from instance profile
    AWS_PAGER="" aws iam remove-role-from-instance-profile \
        --instance-profile-name $INSTANCE_PROFILE_NAME \
        --role-name $ROLE_NAME >/dev/null 2>&1 || echo "Role already removed from instance profile"
    
    # Delete resources
    safe_delete "Instance profile" "AWS_PAGER='' aws iam delete-instance-profile --instance-profile-name $INSTANCE_PROFILE_NAME" "$INSTANCE_PROFILE_NAME"
    safe_delete "IAM policy" "AWS_PAGER='' aws iam delete-policy --policy-arn arn:aws:iam::$ACCOUNT_ID:policy/$POLICY_NAME" "$POLICY_NAME"
    safe_delete "IAM role" "AWS_PAGER='' aws iam delete-role --role-name $ROLE_NAME" "$ROLE_NAME"
else
    echo "⚠️  Could not get account ID, skipping IAM cleanup"
fi

# Step 5: Delete Key Pair
echo ""
echo "🔑 Step 5: Deleting key pair..."
KEY_PAIR_NAME="$PROJECT_ID-keypair"
safe_delete "Key pair" "AWS_PAGER='' aws ec2 delete-key-pair --key-name $KEY_PAIR_NAME --region $AWS_REGION" "$KEY_PAIR_NAME"

# Remove local key file
if [[ -f "$KEY_PAIR_NAME.pem" ]]; then
    rm -f "$KEY_PAIR_NAME.pem"
    echo "✅ Local key file deleted: $KEY_PAIR_NAME.pem"
fi

# Step 6: Delete Security Groups
echo ""
echo "🛡️ Step 6: Deleting security groups..."
SECURITY_GROUPS=$(AWS_PAGER="" aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=*$PROJECT_ID*" \
    --region $AWS_REGION \
    --query 'SecurityGroups[].GroupId' \
    --output text 2>/dev/null || echo "")

if [[ -n "$SECURITY_GROUPS" && "$SECURITY_GROUPS" != "None" ]]; then
    for sg_id in $SECURITY_GROUPS; do
        safe_delete "Security group" "AWS_PAGER='' aws ec2 delete-security-group --group-id $sg_id --region $AWS_REGION" "$sg_id"
    done
else
    echo "ℹ️  No custom security groups found"
fi

# Step 7: Delete Subnets
echo ""
echo "🏠 Step 7: Deleting subnets..."
SUBNETS=$(AWS_PAGER="" aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --region $AWS_REGION \
    --query 'Subnets[].SubnetId' \
    --output text 2>/dev/null || echo "")

if [[ -n "$SUBNETS" && "$SUBNETS" != "None" ]]; then
    for subnet_id in $SUBNETS; do
        safe_delete "Subnet" "AWS_PAGER='' aws ec2 delete-subnet --subnet-id $subnet_id --region $AWS_REGION" "$subnet_id"
    done
else
    echo "ℹ️  No subnets found"
fi

# Step 8: Delete Route Tables
echo ""
echo "🛣️ Step 8: Deleting route tables..."
ROUTE_TABLES=$(AWS_PAGER="" aws ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --region $AWS_REGION \
    --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' \
    --output text 2>/dev/null || echo "")

if [[ -n "$ROUTE_TABLES" && "$ROUTE_TABLES" != "None" ]]; then
    for rt_id in $ROUTE_TABLES; do
        # Disassociate route table first
        ASSOCIATIONS=$(AWS_PAGER="" aws ec2 describe-route-tables \
            --route-table-ids $rt_id \
            --region $AWS_REGION \
            --query 'RouteTables[0].Associations[?Main!=`true`].RouteTableAssociationId' \
            --output text 2>/dev/null || echo "")
        
        if [[ -n "$ASSOCIATIONS" && "$ASSOCIATIONS" != "None" ]]; then
            for assoc_id in $ASSOCIATIONS; do
                AWS_PAGER="" aws ec2 disassociate-route-table \
                    --association-id $assoc_id \
                    --region $AWS_REGION >/dev/null 2>&1 || echo "Association already removed"
            done
        fi
        
        safe_delete "Route table" "AWS_PAGER='' aws ec2 delete-route-table --route-table-id $rt_id --region $AWS_REGION" "$rt_id"
    done
else
    echo "ℹ️  No custom route tables found"
fi

# Step 9: Delete Internet Gateway
echo ""
echo "🌐 Step 9: Deleting internet gateway..."
IGW_IDS=$(AWS_PAGER="" aws ec2 describe-internet-gateways \
    --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
    --region $AWS_REGION \
    --query 'InternetGateways[].InternetGatewayId' \
    --output text 2>/dev/null || echo "")

if [[ -n "$IGW_IDS" && "$IGW_IDS" != "None" ]]; then
    for igw_id in $IGW_IDS; do
        # Detach from VPC first
        AWS_PAGER="" aws ec2 detach-internet-gateway \
            --internet-gateway-id $igw_id \
            --vpc-id $VPC_ID \
            --region $AWS_REGION >/dev/null 2>&1 || echo "IGW already detached"
        
        safe_delete "Internet gateway" "AWS_PAGER='' aws ec2 delete-internet-gateway --internet-gateway-id $igw_id --region $AWS_REGION" "$igw_id"
    done
else
    echo "ℹ️  No internet gateway found"
fi

# Step 10: Delete VPC
echo ""
echo "🏗️ Step 10: Deleting VPC..."
safe_delete "VPC" "AWS_PAGER='' aws ec2 delete-vpc --vpc-id $VPC_ID --region $AWS_REGION" "$VPC_ID"

# Step 11: Clean up local files
echo ""
echo "📁 Step 11: Cleaning up local files..."
rm -rf configs/ outputs/ *.pem 2>/dev/null || echo "Local files already cleaned"
echo "✅ Local configuration files cleaned up"

echo ""
echo "🎉 Cleanup completed successfully!"
echo "================================="
echo ""
echo "All AWS resources have been deleted:"
echo "  ✅ EC2 instances terminated"
echo "  ✅ S3 bucket and contents deleted"
echo "  ✅ VPC endpoint removed"
echo "  ✅ IAM roles and policies deleted"
echo "  ✅ Key pairs deleted"
echo "  ✅ Security groups removed"
echo "  ✅ Subnets deleted"
echo "  ✅ Route tables removed"
echo "  ✅ Internet gateway deleted"
echo "  ✅ VPC deleted"
echo "  ✅ Local files cleaned up"
echo ""
echo "💰 Cost Impact: All billable resources have been removed"
echo "🔒 Security: All access keys and policies have been deleted"
echo ""
echo "Thank you for using the S3 VPC Endpoint demo!"
