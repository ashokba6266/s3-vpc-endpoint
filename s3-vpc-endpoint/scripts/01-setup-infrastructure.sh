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

echo "🚀 Setting up S3 VPC Endpoint Infrastructure"
echo "============================================="
echo "Project ID: $PROJECT_ID"
echo "Region: $AWS_REGION"
echo "VPC CIDR: $VPC_CIDR"
echo ""

# Create VPC
echo "📡 Creating VPC..."
VPC_ID=$(aws ec2 create-vpc \
    --cidr-block $VPC_CIDR \
    --enable-dns-hostnames \
    --enable-dns-support \
    --tag-specifications "ResourceType=vpc,Tags=[
        {Key=Name,Value=$PROJECT_ID-vpc},
        {Key=Project,Value=$PROJECT_NAME},
        {Key=Environment,Value=development},
        {Key=Purpose,Value=s3-endpoint-demo}
    ]" \
    --region $AWS_REGION \
    --query 'Vpc.VpcId' \
    --output text)

echo "✅ VPC created: $VPC_ID"

# Create Internet Gateway
echo "🌐 Creating Internet Gateway..."
IGW_ID=$(aws ec2 create-internet-gateway \
    --tag-specifications "ResourceType=internet-gateway,Tags=[
        {Key=Name,Value=$PROJECT_ID-igw},
        {Key=Project,Value=$PROJECT_NAME}
    ]" \
    --region $AWS_REGION \
    --query 'InternetGateway.InternetGatewayId' \
    --output text)

# Attach Internet Gateway to VPC
aws ec2 attach-internet-gateway \
    --internet-gateway-id $IGW_ID \
    --vpc-id $VPC_ID \
    --region $AWS_REGION

echo "✅ Internet Gateway created and attached: $IGW_ID"

# Get availability zones
AZ_LIST=($(aws ec2 describe-availability-zones \
    --region $AWS_REGION \
    --query 'AvailabilityZones[0:2].ZoneName' \
    --output text))

AZ_PRIMARY=${AZ_LIST[0]}
AZ_SECONDARY=${AZ_LIST[1]:-$AZ_PRIMARY}

echo "🏢 Using Availability Zones: $AZ_PRIMARY, $AZ_SECONDARY"

# Create Public Subnet
echo "🔓 Creating public subnet..."
PUBLIC_SUBNET_ID=$(aws ec2 create-subnet \
    --vpc-id $VPC_ID \
    --cidr-block $PUBLIC_SUBNET_CIDR \
    --availability-zone $AZ_PRIMARY \
    --tag-specifications "ResourceType=subnet,Tags=[
        {Key=Name,Value=$PROJECT_ID-public-subnet},
        {Key=Project,Value=$PROJECT_NAME},
        {Key=Type,Value=Public}
    ]" \
    --region $AWS_REGION \
    --query 'Subnet.SubnetId' \
    --output text)

# Enable auto-assign public IP for public subnet
aws ec2 modify-subnet-attribute \
    --subnet-id $PUBLIC_SUBNET_ID \
    --map-public-ip-on-launch \
    --region $AWS_REGION

echo "✅ Public subnet created: $PUBLIC_SUBNET_ID"

# Create Private Subnet
echo "🔒 Creating private subnet..."
PRIVATE_SUBNET_ID=$(aws ec2 create-subnet \
    --vpc-id $VPC_ID \
    --cidr-block $PRIVATE_SUBNET_CIDR \
    --availability-zone $AZ_PRIMARY \
    --tag-specifications "ResourceType=subnet,Tags=[
        {Key=Name,Value=$PROJECT_ID-private-subnet},
        {Key=Project,Value=$PROJECT_NAME},
        {Key=Type,Value=Private}
    ]" \
    --region $AWS_REGION \
    --query 'Subnet.SubnetId' \
    --output text)

echo "✅ Private subnet created: $PRIVATE_SUBNET_ID"

# Create Public Route Table
echo "🛣️ Creating public route table..."
PUBLIC_RT_ID=$(aws ec2 create-route-table \
    --vpc-id $VPC_ID \
    --tag-specifications "ResourceType=route-table,Tags=[
        {Key=Name,Value=$PROJECT_ID-public-rt},
        {Key=Project,Value=$PROJECT_NAME},
        {Key=Type,Value=Public}
    ]" \
    --region $AWS_REGION \
    --query 'RouteTable.RouteTableId' \
    --output text)

# Add route to Internet Gateway
aws ec2 create-route \
    --route-table-id $PUBLIC_RT_ID \
    --destination-cidr-block 0.0.0.0/0 \
    --gateway-id $IGW_ID \
    --region $AWS_REGION

# Associate public subnet with public route table
aws ec2 associate-route-table \
    --subnet-id $PUBLIC_SUBNET_ID \
    --route-table-id $PUBLIC_RT_ID \
    --region $AWS_REGION

echo "✅ Public route table created and configured: $PUBLIC_RT_ID"

# Create Private Route Table
echo "🛣️ Creating private route table..."
PRIVATE_RT_ID=$(aws ec2 create-route-table \
    --vpc-id $VPC_ID \
    --tag-specifications "ResourceType=route-table,Tags=[
        {Key=Name,Value=$PROJECT_ID-private-rt},
        {Key=Project,Value=$PROJECT_NAME},
        {Key=Type,Value=Private}
    ]" \
    --region $AWS_REGION \
    --query 'RouteTable.RouteTableId' \
    --output text)

# Associate private subnet with private route table
aws ec2 associate-route-table \
    --subnet-id $PRIVATE_SUBNET_ID \
    --route-table-id $PRIVATE_RT_ID \
    --region $AWS_REGION

echo "✅ Private route table created and configured: $PRIVATE_RT_ID"

# Create Security Group for Bastion Host
echo "🛡️ Creating bastion security group..."
BASTION_SG_ID=$(aws ec2 create-security-group \
    --group-name "$PROJECT_ID-bastion-sg" \
    --description "Security group for bastion host" \
    --vpc-id $VPC_ID \
    --tag-specifications "ResourceType=security-group,Tags=[
        {Key=Name,Value=$PROJECT_ID-bastion-sg},
        {Key=Project,Value=$PROJECT_NAME}
    ]" \
    --region $AWS_REGION \
    --query 'GroupId' \
    --output text)

# Add SSH access rule (restrict to your IP in production)
aws ec2 authorize-security-group-ingress \
    --group-id $BASTION_SG_ID \
    --protocol tcp \
    --port 22 \
    --cidr 0.0.0.0/0 \
    --region $AWS_REGION

echo "✅ Bastion security group created: $BASTION_SG_ID"

# Create Security Group for Private Instances
echo "🛡️ Creating private instance security group..."
PRIVATE_SG_ID=$(aws ec2 create-security-group \
    --group-name "$PROJECT_ID-private-sg" \
    --description "Security group for private instances" \
    --vpc-id $VPC_ID \
    --tag-specifications "ResourceType=security-group,Tags=[
        {Key=Name,Value=$PROJECT_ID-private-sg},
        {Key=Project,Value=$PROJECT_NAME}
    ]" \
    --region $AWS_REGION \
    --query 'GroupId' \
    --output text)

# Add SSH access from bastion
aws ec2 authorize-security-group-ingress \
    --group-id $PRIVATE_SG_ID \
    --protocol tcp \
    --port 22 \
    --source-group $BASTION_SG_ID \
    --region $AWS_REGION

echo "✅ Private security group created: $PRIVATE_SG_ID"

# Create S3 bucket for testing
S3_BUCKET_NAME="$PROJECT_ID-test-bucket"
echo "🪣 Creating S3 test bucket: $S3_BUCKET_NAME"

if [ "$AWS_REGION" = "us-east-1" ]; then
    aws s3api create-bucket \
        --bucket $S3_BUCKET_NAME \
        --region $AWS_REGION
else
    aws s3api create-bucket \
        --bucket $S3_BUCKET_NAME \
        --region $AWS_REGION \
        --create-bucket-configuration LocationConstraint=$AWS_REGION
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

aws s3api put-bucket-policy \
    --bucket $S3_BUCKET_NAME \
    --policy file:///tmp/s3-bucket-policy.json

# Tag the S3 bucket
aws s3api put-bucket-tagging \
    --bucket $S3_BUCKET_NAME \
    --tagging 'TagSet=[
        {Key=Name,Value='$PROJECT_ID'-test-bucket},
        {Key=Project,Value='$PROJECT_NAME'},
        {Key=Purpose,Value=endpoint-testing}
    ]'

echo "✅ S3 test bucket created and configured: $S3_BUCKET_NAME"

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
