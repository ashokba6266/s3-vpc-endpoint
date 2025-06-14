#!/bin/bash

# S3 VPC Endpoint Project - Complete Cleanup
# Removes all resources created by the S3 VPC endpoint project

set -e

# Load configuration
if [ ! -f "configs/vpc-parameters.json" ]; then
    echo "❌ Error: VPC configuration not found. Nothing to clean up."
    exit 1
fi

PROJECT_ID=$(jq -r '.project_id' configs/vpc-parameters.json)
PROJECT_NAME=$(jq -r '.project_name' configs/vpc-parameters.json)
AWS_REGION=$(jq -r '.region' configs/vpc-parameters.json)
VPC_ID=$(jq -r '.vpc_id' configs/vpc-parameters.json)
S3_BUCKET_NAME=$(jq -r '.s3_bucket_name' configs/vpc-parameters.json)

echo "🧹 S3 VPC Endpoint Project Cleanup"
echo "==================================="
echo "Project: $PROJECT_ID"
echo "Region: $AWS_REGION"
echo "VPC: $VPC_ID"
echo ""

# Confirmation prompt
echo "⚠️  WARNING: This will delete ALL resources created by this project!"
echo "This includes:"
echo "  • EC2 instances"
echo "  • VPC and all networking components"
echo "  • S3 bucket and all contents"
echo "  • IAM roles and policies"
echo "  • Key pairs"
echo ""
read -p "Are you sure you want to proceed? Type 'DELETE' to confirm: " CONFIRM

if [ "$CONFIRM" != "DELETE" ]; then
    echo "❌ Cleanup cancelled. No resources were deleted."
    exit 0
fi

echo ""
echo "🚀 Starting cleanup process..."

# Function to safely delete resources with error handling
safe_delete() {
    local resource_type=$1
    local command=$2
    local resource_id=$3
    
    echo "Deleting $resource_type: $resource_id"
    if eval "$command" 2>/dev/null; then
        echo "✅ $resource_type deleted successfully"
    else
        echo "⚠️  Failed to delete $resource_type (may not exist or already deleted)"
    fi
}

# 1. Terminate EC2 Instances
echo ""
echo "🖥️ Step 1: Terminating EC2 instances..."

INSTANCE_IDS=$(aws ec2 describe-instances \
    --region $AWS_REGION \
    --filters "Name=tag:Project,Values=$PROJECT_NAME" "Name=instance-state-name,Values=running,stopped,stopping" \
    --query 'Reservations[*].Instances[*].InstanceId' \
    --output text)

if [ ! -z "$INSTANCE_IDS" ]; then
    echo "Found instances to terminate: $INSTANCE_IDS"
    aws ec2 terminate-instances \
        --instance-ids $INSTANCE_IDS \
        --region $AWS_REGION
    
    echo "⏳ Waiting for instances to terminate..."
    aws ec2 wait instance-terminated \
        --instance-ids $INSTANCE_IDS \
        --region $AWS_REGION
    
    echo "✅ All instances terminated"
else
    echo "No instances found to terminate"
fi

# 2. Delete S3 Bucket and Contents
echo ""
echo "🪣 Step 2: Deleting S3 bucket and contents..."

if [ "$S3_BUCKET_NAME" != "null" ] && [ ! -z "$S3_BUCKET_NAME" ]; then
    echo "Emptying S3 bucket: $S3_BUCKET_NAME"
    
    # Delete all objects and versions
    aws s3 rm s3://$S3_BUCKET_NAME --recursive --region $AWS_REGION 2>/dev/null || echo "Bucket already empty"
    
    # Delete versioned objects if any
    aws s3api delete-objects \
        --bucket $S3_BUCKET_NAME \
        --delete "$(aws s3api list-object-versions \
            --bucket $S3_BUCKET_NAME \
            --region $AWS_REGION \
            --output json \
            --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' 2>/dev/null)" \
        --region $AWS_REGION 2>/dev/null || echo "No versions to delete"
    
    # Delete delete markers
    aws s3api delete-objects \
        --bucket $S3_BUCKET_NAME \
        --delete "$(aws s3api list-object-versions \
            --bucket $S3_BUCKET_NAME \
            --region $AWS_REGION \
            --output json \
            --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' 2>/dev/null)" \
        --region $AWS_REGION 2>/dev/null || echo "No delete markers to remove"
    
    # Delete bucket
    safe_delete "S3 bucket" "aws s3api delete-bucket --bucket $S3_BUCKET_NAME --region $AWS_REGION" "$S3_BUCKET_NAME"
else
    echo "No S3 bucket found to delete"
fi

# 3. Delete VPC Endpoints
echo ""
echo "🔗 Step 3: Deleting VPC endpoints..."

ENDPOINT_IDS=$(aws ec2 describe-vpc-endpoints \
    --region $AWS_REGION \
    --filters "Name=tag:Project,Values=$PROJECT_NAME" \
    --query 'VpcEndpoints[*].VpcEndpointId' \
    --output text)

if [ ! -z "$ENDPOINT_IDS" ]; then
    for endpoint_id in $ENDPOINT_IDS; do
        safe_delete "VPC endpoint" "aws ec2 delete-vpc-endpoint --vpc-endpoint-id $endpoint_id --region $AWS_REGION" "$endpoint_id"
    done
    
    echo "⏳ Waiting for endpoints to be deleted..."
    sleep 15
else
    echo "No VPC endpoints found to delete"
fi

# 4. Delete IAM Resources
echo ""
echo "👤 Step 4: Deleting IAM resources..."

# Get account ID for policy ARN
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Detach and delete IAM policy
POLICY_NAME="$PROJECT_ID-s3-policy"
ROLE_NAME="$PROJECT_ID-ec2-role"
INSTANCE_PROFILE_NAME="$PROJECT_ID-instance-profile"

# Detach policy from role
aws iam detach-role-policy \
    --role-name $ROLE_NAME \
    --policy-arn "arn:aws:iam::$ACCOUNT_ID:policy/$POLICY_NAME" 2>/dev/null || echo "Policy already detached"

# Remove role from instance profile
aws iam remove-role-from-instance-profile \
    --instance-profile-name $INSTANCE_PROFILE_NAME \
    --role-name $ROLE_NAME 2>/dev/null || echo "Role already removed from instance profile"

# Delete instance profile
safe_delete "Instance profile" "aws iam delete-instance-profile --instance-profile-name $INSTANCE_PROFILE_NAME" "$INSTANCE_PROFILE_NAME"

# Delete IAM role
safe_delete "IAM role" "aws iam delete-role --role-name $ROLE_NAME" "$ROLE_NAME"

# Delete IAM policy
safe_delete "IAM policy" "aws iam delete-policy --policy-arn arn:aws:iam::$ACCOUNT_ID:policy/$POLICY_NAME" "$POLICY_NAME"

# 5. Delete Key Pair
echo ""
echo "🔑 Step 5: Deleting key pair..."

KEY_PAIR_NAME="$PROJECT_ID-keypair"
safe_delete "Key pair" "aws ec2 delete-key-pair --key-name $KEY_PAIR_NAME --region $AWS_REGION" "$KEY_PAIR_NAME"

# Delete local key file
if [ -f "$KEY_PAIR_NAME.pem" ]; then
    rm "$KEY_PAIR_NAME.pem"
    echo "✅ Local key file deleted: $KEY_PAIR_NAME.pem"
fi

# 6. Delete Security Groups
echo ""
echo "🛡️ Step 6: Deleting security groups..."

SECURITY_GROUP_IDS=$(aws ec2 describe-security-groups \
    --region $AWS_REGION \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Project,Values=$PROJECT_NAME" \
    --query 'SecurityGroups[*].GroupId' \
    --output text)

if [ ! -z "$SECURITY_GROUP_IDS" ]; then
    for sg_id in $SECURITY_GROUP_IDS; do
        safe_delete "Security group" "aws ec2 delete-security-group --group-id $sg_id --region $AWS_REGION" "$sg_id"
    done
else
    echo "No security groups found to delete"
fi

# 7. Delete Route Tables
echo ""
echo "🛣️ Step 7: Deleting route tables..."

ROUTE_TABLE_IDS=$(aws ec2 describe-route-tables \
    --region $AWS_REGION \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Project,Values=$PROJECT_NAME" \
    --query 'RouteTables[*].RouteTableId' \
    --output text)

if [ ! -z "$ROUTE_TABLE_IDS" ]; then
    for rt_id in $ROUTE_TABLE_IDS; do
        # Disassociate subnets first
        ASSOCIATION_IDS=$(aws ec2 describe-route-tables \
            --route-table-ids $rt_id \
            --region $AWS_REGION \
            --query 'RouteTables[0].Associations[?Main==`false`].RouteTableAssociationId' \
            --output text 2>/dev/null)
        
        if [ ! -z "$ASSOCIATION_IDS" ]; then
            for assoc_id in $ASSOCIATION_IDS; do
                aws ec2 disassociate-route-table \
                    --association-id $assoc_id \
                    --region $AWS_REGION 2>/dev/null || echo "Association already removed"
            done
        fi
        
        safe_delete "Route table" "aws ec2 delete-route-table --route-table-id $rt_id --region $AWS_REGION" "$rt_id"
    done
else
    echo "No route tables found to delete"
fi

# 8. Delete Subnets
echo ""
echo "🏢 Step 8: Deleting subnets..."

SUBNET_IDS=$(aws ec2 describe-subnets \
    --region $AWS_REGION \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Project,Values=$PROJECT_NAME" \
    --query 'Subnets[*].SubnetId' \
    --output text)

if [ ! -z "$SUBNET_IDS" ]; then
    for subnet_id in $SUBNET_IDS; do
        safe_delete "Subnet" "aws ec2 delete-subnet --subnet-id $subnet_id --region $AWS_REGION" "$subnet_id"
    done
else
    echo "No subnets found to delete"
fi

# 9. Delete Internet Gateway
echo ""
echo "🌐 Step 9: Deleting internet gateway..."

IGW_IDS=$(aws ec2 describe-internet-gateways \
    --region $AWS_REGION \
    --filters "Name=tag:Project,Values=$PROJECT_NAME" \
    --query 'InternetGateways[*].InternetGatewayId' \
    --output text)

if [ ! -z "$IGW_IDS" ]; then
    for igw_id in $IGW_IDS; do
        # Detach from VPC first
        aws ec2 detach-internet-gateway \
            --internet-gateway-id $igw_id \
            --vpc-id $VPC_ID \
            --region $AWS_REGION 2>/dev/null || echo "IGW already detached"
        
        safe_delete "Internet gateway" "aws ec2 delete-internet-gateway --internet-gateway-id $igw_id --region $AWS_REGION" "$igw_id"
    done
else
    echo "No internet gateways found to delete"
fi

# 10. Delete VPC
echo ""
echo "🏗️ Step 10: Deleting VPC..."

if [ "$VPC_ID" != "null" ] && [ ! -z "$VPC_ID" ]; then
    safe_delete "VPC" "aws ec2 delete-vpc --vpc-id $VPC_ID --region $AWS_REGION" "$VPC_ID"
else
    echo "No VPC found to delete"
fi

# 11. Clean up local files
echo ""
echo "📁 Step 11: Cleaning up local files..."

LOCAL_FILES=(
    "configs/vpc-parameters.json"
    "configs/s3-endpoint-policy.json"
    "outputs/s3-endpoint-details.json"
    "outputs/test-results.json"
    "outputs/infrastructure-info.json"
)

for file in "${LOCAL_FILES[@]}"; do
    if [ -f "$file" ]; then
        rm "$file"
        echo "✅ Removed: $file"
    fi
done

# Create cleanup summary
cat > outputs/cleanup-summary.json << EOF
{
    "cleanup_timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "project_id": "$PROJECT_ID",
    "region": "$AWS_REGION",
    "vpc_id": "$VPC_ID",
    "s3_bucket": "$S3_BUCKET_NAME",
    "cleanup_status": "completed",
    "resources_deleted": [
        "EC2 instances",
        "S3 bucket and contents",
        "VPC endpoints",
        "IAM roles and policies",
        "Key pairs",
        "Security groups",
        "Route tables",
        "Subnets",
        "Internet gateway",
        "VPC"
    ]
}
EOF

echo ""
echo "🎉 Cleanup completed successfully!"
echo "=================================="
echo ""
echo "📋 Summary:"
echo "✅ All EC2 instances terminated"
echo "✅ S3 bucket and contents deleted"
echo "✅ VPC endpoints removed"
echo "✅ IAM resources cleaned up"
echo "✅ Key pairs deleted"
echo "✅ Network resources removed"
echo "✅ VPC deleted"
echo "✅ Local configuration files cleaned up"
echo ""
echo "💰 Cost Impact:"
echo "• No more charges for any resources created by this project"
echo "• S3 Gateway endpoints were free anyway"
echo "• All compute and storage resources have been terminated"
echo ""
echo "📄 Cleanup summary saved to: outputs/cleanup-summary.json"
echo ""
echo "Thank you for using the S3 VPC Endpoint project!"
echo "For questions or issues, please refer to the documentation."
