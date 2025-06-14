#!/bin/bash

# S3 VPC Endpoint Project - Infrastructure Setup
# Creates VPC, subnets, route tables, and security groups

set -e

# Configuration
PROJECT_NAME="s3-vpc-endpoint"
PROJECT_ID=${PROJECT_ID:-"s3-vpc-endpoint-$(date +%s)"}
AWS_REGION=${AWS_REGION:-us-east-1}

# Network Configuration
VPC_CIDR="10.0.0.0/16"
PUBLIC_SUBNET_CIDR="10.0.1.0/24"
PRIVATE_SUBNET_CIDR="10.0.2.0/24"

# Function to extract VPC ID from AWS CLI output
extract_vpc_id() {
    local output="$1"
    echo "$output" | grep -E '^vpc-[a-f0-9]+$' | tail -1
}

# Function to extract other resource IDs
extract_resource_id() {
    local output="$1"
    local resource_type="$2"
    echo "$output" | grep -E "^${resource_type}-[a-f0-9]+$" | tail -1
}

echo "🚀 Setting up S3 VPC Endpoint Infrastructure"
echo "============================================="
echo "Project ID: $PROJECT_ID"
echo "Region: $AWS_REGION"
echo "VPC CIDR: $VPC_CIDR"
echo ""

# Create VPC
echo "📡 Creating VPC..."
VPC_OUTPUT=$(AWS_PAGER="" aws ec2 create-vpc \
    --cidr-block $VPC_CIDR \
    --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$PROJECT_ID-vpc},{Key=Project,Value=$PROJECT_NAME},{Key=Environment,Value=development},{Key=Purpose,Value=s3-endpoint-demo}]" \
    --region $AWS_REGION \
    --query 'Vpc.VpcId' \
    --output text 2>/dev/null)

VPC_ID=$(extract_vpc_id "$VPC_OUTPUT")

if [[ -z "$VPC_ID" || ! "$VPC_ID" =~ ^vpc-[a-f0-9]+$ ]]; then
    echo "❌ Failed to create VPC or extract VPC ID"
    echo "Output: $VPC_OUTPUT"
    exit 1
fi

echo "✅ VPC created: $VPC_ID"

# Enable DNS hostnames and DNS support
echo "🔧 Enabling DNS settings for VPC..."
AWS_PAGER="" aws ec2 modify-vpc-attribute \
    --vpc-id $VPC_ID \
    --enable-dns-hostnames \
    --region $AWS_REGION >/dev/null 2>&1

AWS_PAGER="" aws ec2 modify-vpc-attribute \
    --vpc-id $VPC_ID \
    --enable-dns-support \
    --region $AWS_REGION >/dev/null 2>&1

echo "✅ DNS settings enabled for VPC"

# Create Internet Gateway
echo "🌐 Creating Internet Gateway..."
IGW_OUTPUT=$(AWS_PAGER="" aws ec2 create-internet-gateway \
    --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=$PROJECT_ID-igw},{Key=Project,Value=$PROJECT_NAME}]" \
    --region $AWS_REGION \
    --query 'InternetGateway.InternetGatewayId' \
    --output text 2>/dev/null)

IGW_ID=$(extract_resource_id "$IGW_OUTPUT" "igw")

if [[ -z "$IGW_ID" || ! "$IGW_ID" =~ ^igw-[a-f0-9]+$ ]]; then
    echo "❌ Failed to create Internet Gateway"
    exit 1
fi

# Attach Internet Gateway to VPC
AWS_PAGER="" aws ec2 attach-internet-gateway \
    --internet-gateway-id $IGW_ID \
    --vpc-id $VPC_ID \
    --region $AWS_REGION >/dev/null 2>&1

echo "✅ Internet Gateway created and attached: $IGW_ID"

# Get availability zones
AZ_OUTPUT=$(AWS_PAGER="" aws ec2 describe-availability-zones \
    --region $AWS_REGION \
    --query 'AvailabilityZones[0:2].ZoneName' \
    --output text 2>/dev/null)

AZ_LIST=($(echo "$AZ_OUTPUT" | grep -E '^[a-z]+-[a-z]+-[0-9]+[a-z]' | head -2))
AZ_PRIMARY=${AZ_LIST[0]}
AZ_SECONDARY=${AZ_LIST[1]:-$AZ_PRIMARY}

echo "🏢 Using Availability Zones: $AZ_PRIMARY, $AZ_SECONDARY"

# Create Public Subnet
echo "🔓 Creating public subnet..."
PUBLIC_SUBNET_OUTPUT=$(AWS_PAGER="" aws ec2 create-subnet \
    --vpc-id $VPC_ID \
    --cidr-block $PUBLIC_SUBNET_CIDR \
    --availability-zone $AZ_PRIMARY \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$PROJECT_ID-public-subnet},{Key=Project,Value=$PROJECT_NAME},{Key=Type,Value=Public}]" \
    --region $AWS_REGION \
    --query 'Subnet.SubnetId' \
    --output text 2>/dev/null)

PUBLIC_SUBNET_ID=$(extract_resource_id "$PUBLIC_SUBNET_OUTPUT" "subnet")

# Enable auto-assign public IP for public subnet
AWS_PAGER="" aws ec2 modify-subnet-attribute \
    --subnet-id $PUBLIC_SUBNET_ID \
    --map-public-ip-on-launch \
    --region $AWS_REGION >/dev/null 2>&1

echo "✅ Public subnet created: $PUBLIC_SUBNET_ID"

# Create Private Subnet
echo "🔒 Creating private subnet..."
PRIVATE_SUBNET_OUTPUT=$(AWS_PAGER="" aws ec2 create-subnet \
    --vpc-id $VPC_ID \
    --cidr-block $PRIVATE_SUBNET_CIDR \
    --availability-zone $AZ_PRIMARY \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$PROJECT_ID-private-subnet},{Key=Project,Value=$PROJECT_NAME},{Key=Type,Value=Private}]" \
    --region $AWS_REGION \
    --query 'Subnet.SubnetId' \
    --output text 2>/dev/null)

PRIVATE_SUBNET_ID=$(extract_resource_id "$PRIVATE_SUBNET_OUTPUT" "subnet")

echo "✅ Private subnet created: $PRIVATE_SUBNET_ID"

# Create Public Route Table
echo "🛣️ Creating public route table..."
PUBLIC_RT_OUTPUT=$(AWS_PAGER="" aws ec2 create-route-table \
    --vpc-id $VPC_ID \
    --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=$PROJECT_ID-public-rt},{Key=Project,Value=$PROJECT_NAME},{Key=Type,Value=Public}]" \
    --region $AWS_REGION \
    --query 'RouteTable.RouteTableId' \
    --output text 2>/dev/null)

PUBLIC_RT_ID=$(extract_resource_id "$PUBLIC_RT_OUTPUT" "rtb")

# Add route to Internet Gateway
AWS_PAGER="" aws ec2 create-route \
    --route-table-id $PUBLIC_RT_ID \
    --destination-cidr-block 0.0.0.0/0 \
    --gateway-id $IGW_ID \
    --region $AWS_REGION >/dev/null 2>&1

# Associate public subnet with public route table
AWS_PAGER="" aws ec2 associate-route-table \
    --subnet-id $PUBLIC_SUBNET_ID \
    --route-table-id $PUBLIC_RT_ID \
    --region $AWS_REGION >/dev/null 2>&1

echo "✅ Public route table created and configured: $PUBLIC_RT_ID"

# Create Private Route Table
echo "🛣️ Creating private route table..."
PRIVATE_RT_OUTPUT=$(AWS_PAGER="" aws ec2 create-route-table \
    --vpc-id $VPC_ID \
    --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=$PROJECT_ID-private-rt},{Key=Project,Value=$PROJECT_NAME},{Key=Type,Value=Private}]" \
    --region $AWS_REGION \
    --query 'RouteTable.RouteTableId' \
    --output text 2>/dev/null)

PRIVATE_RT_ID=$(extract_resource_id "$PRIVATE_RT_OUTPUT" "rtb")

# Associate private subnet with private route table
AWS_PAGER="" aws ec2 associate-route-table \
    --subnet-id $PRIVATE_SUBNET_ID \
    --route-table-id $PRIVATE_RT_ID \
    --region $AWS_REGION >/dev/null 2>&1

echo "✅ Private route table created and configured: $PRIVATE_RT_ID"

# Create Security Group for Bastion Host
echo "🛡️ Creating bastion security group..."
BASTION_SG_OUTPUT=$(AWS_PAGER="" aws ec2 create-security-group \
    --group-name "$PROJECT_ID-bastion-sg" \
    --description "Security group for bastion host" \
    --vpc-id $VPC_ID \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$PROJECT_ID-bastion-sg},{Key=Project,Value=$PROJECT_NAME}]" \
    --region $AWS_REGION \
    --query 'GroupId' \
    --output text 2>/dev/null)

BASTION_SG_ID=$(extract_resource_id "$BASTION_SG_OUTPUT" "sg")

# Add SSH access rule (restrict to your IP in production)
AWS_PAGER="" aws ec2 authorize-security-group-ingress \
    --group-id $BASTION_SG_ID \
    --protocol tcp \
    --port 22 \
    --cidr 0.0.0.0/0 \
    --region $AWS_REGION >/dev/null 2>&1

echo "✅ Bastion security group created: $BASTION_SG_ID"

# Create Security Group for Private Instances
echo "🛡️ Creating private instance security group..."
PRIVATE_SG_OUTPUT=$(AWS_PAGER="" aws ec2 create-security-group \
    --group-name "$PROJECT_ID-private-sg" \
    --description "Security group for private instances" \
    --vpc-id $VPC_ID \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$PROJECT_ID-private-sg},{Key=Project,Value=$PROJECT_NAME}]" \
    --region $AWS_REGION \
    --query 'GroupId' \
    --output text 2>/dev/null)

PRIVATE_SG_ID=$(extract_resource_id "$PRIVATE_SG_OUTPUT" "sg")

# Add SSH access from bastion
AWS_PAGER="" aws ec2 authorize-security-group-ingress \
    --group-id $PRIVATE_SG_ID \
    --protocol tcp \
    --port 22 \
    --source-group $BASTION_SG_ID \
    --region $AWS_REGION >/dev/null 2>&1

echo "✅ Private security group created: $PRIVATE_SG_ID"

# Create S3 bucket for testing
S3_BUCKET_NAME="$PROJECT_ID-test-bucket"
echo "🪣 Creating S3 test bucket: $S3_BUCKET_NAME"

if [ "$AWS_REGION" = "us-east-1" ]; then
    AWS_PAGER="" aws s3api create-bucket \
        --bucket $S3_BUCKET_NAME \
        --region $AWS_REGION >/dev/null 2>&1
else
    AWS_PAGER="" aws s3api create-bucket \
        --bucket $S3_BUCKET_NAME \
        --region $AWS_REGION \
        --create-bucket-configuration LocationConstraint=$AWS_REGION >/dev/null 2>&1
fi

# Configure bucket policy for VPC endpoint access
cat > /tmp/s3-bucket-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "VPCEndpointAccess",
            "Effect": "Allow",
            "Principal": "*",
            "Action": "s3:*",
            "Resource": [
                "arn:aws:s3:::$S3_BUCKET_NAME",
                "arn:aws:s3:::$S3_BUCKET_NAME/*"
            ],
            "Condition": {
                "StringEquals": {
                    "aws:sourceVpc": "$VPC_ID"
                }
            }
        }
    ]
}
EOF

AWS_PAGER="" aws s3api put-bucket-policy \
    --bucket $S3_BUCKET_NAME \
    --policy file:///tmp/s3-bucket-policy.json >/dev/null 2>&1

# Tag the S3 bucket
AWS_PAGER="" aws s3api put-bucket-tagging \
    --bucket $S3_BUCKET_NAME \
    --tagging "TagSet=[{Key=Name,Value=$PROJECT_ID-test-bucket},{Key=Project,Value=$PROJECT_NAME},{Key=Purpose,Value=endpoint-testing}]" >/dev/null 2>&1

echo "✅ S3 test bucket created and configured: $S3_BUCKET_NAME"

# Create configs directory if it doesn't exist
mkdir -p configs

# Save infrastructure configuration
cat > configs/vpc-parameters.json << EOF
{
  "project_id": "$PROJECT_ID",
  "project_name": "$PROJECT_NAME",
  "region": "$AWS_REGION",
  "vpc_id": "$VPC_ID",
  "vpc_cidr": "$VPC_CIDR",
  "public_subnet_id": "$PUBLIC_SUBNET_ID",
  "private_subnet_id": "$PRIVATE_SUBNET_ID",
  "public_route_table_id": "$PUBLIC_RT_ID",
  "private_route_table_id": "$PRIVATE_RT_ID",
  "internet_gateway_id": "$IGW_ID",
  "bastion_security_group_id": "$BASTION_SG_ID",
  "private_security_group_id": "$PRIVATE_SG_ID",
  "availability_zone_primary": "$AZ_PRIMARY",
  "availability_zone_secondary": "$AZ_SECONDARY",
  "s3_bucket_name": "$S3_BUCKET_NAME",
  "created_timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

# Clean up temporary files
rm -f /tmp/s3-bucket-policy.json

echo ""
echo "🎉 Infrastructure setup completed successfully!"
echo "=============================================="
echo ""
echo "📋 Created Resources:"
echo "   VPC: $VPC_ID"
echo "   Public Subnet: $PUBLIC_SUBNET_ID"
echo "   Private Subnet: $PRIVATE_SUBNET_ID"
echo "   Internet Gateway: $IGW_ID"
echo "   Public Route Table: $PUBLIC_RT_ID"
echo "   Private Route Table: $PRIVATE_RT_ID"
echo "   Bastion Security Group: $BASTION_SG_ID"
echo "   Private Security Group: $PRIVATE_SG_ID"
echo "   S3 Test Bucket: $S3_BUCKET_NAME"
echo ""
echo "📄 Configuration saved to: configs/vpc-parameters.json"
echo ""
echo "➡️  Next step: Run ./scripts/02-create-s3-endpoint.sh"
