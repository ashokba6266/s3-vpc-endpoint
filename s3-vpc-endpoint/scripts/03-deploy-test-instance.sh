#!/bin/bash

# S3 VPC Endpoint Project - Deploy Test Instance
# Deploys EC2 instances for testing S3 endpoint connectivity

set -e

# Load configuration
if [ ! -f "configs/vpc-parameters.json" ]; then
    echo "❌ Error: VPC configuration not found. Please run previous scripts first."
    exit 1
fi

PROJECT_ID=$(jq -r '.project_id' configs/vpc-parameters.json)
PROJECT_NAME=$(jq -r '.project_name' configs/vpc-parameters.json)
AWS_REGION=$(jq -r '.region' configs/vpc-parameters.json)
VPC_ID=$(jq -r '.vpc_id' configs/vpc-parameters.json)
PUBLIC_SUBNET_ID=$(jq -r '.public_subnet_id' configs/vpc-parameters.json)
PRIVATE_SUBNET_ID=$(jq -r '.private_subnet_id' configs/vpc-parameters.json)
BASTION_SG_ID=$(jq -r '.bastion_security_group_id' configs/vpc-parameters.json)
PRIVATE_SG_ID=$(jq -r '.private_security_group_id' configs/vpc-parameters.json)
S3_BUCKET_NAME=$(jq -r '.s3_bucket_name' configs/vpc-parameters.json)

echo "🚀 Deploying Test Instances for S3 Endpoint"
echo "============================================"
echo "Project: $PROJECT_ID"
echo "Region: $AWS_REGION"
echo "VPC: $VPC_ID"
echo ""

# Get latest Amazon Linux 2 AMI
echo "🔍 Finding latest Amazon Linux 2 AMI..."
AMI_ID=$(aws ec2 describe-images \
    --owners amazon \
    --filters "Name=name,Values=amzn2-ami-hvm-*-x86_64-gp2" \
              "Name=state,Values=available" \
    --region $AWS_REGION \
    --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
    --output text)

echo "✅ Using AMI: $AMI_ID"

# Create key pair for SSH access
KEY_PAIR_NAME="$PROJECT_ID-keypair"
echo "🔑 Creating key pair: $KEY_PAIR_NAME"

if aws ec2 describe-key-pairs --key-names $KEY_PAIR_NAME --region $AWS_REGION > /dev/null 2>&1; then
    echo "⚠️  Key pair already exists, skipping creation"
else
    aws ec2 create-key-pair \
        --key-name $KEY_PAIR_NAME \
        --region $AWS_REGION \
        --query 'KeyMaterial' \
        --output text > $KEY_PAIR_NAME.pem
    
    chmod 400 $KEY_PAIR_NAME.pem
    echo "✅ Key pair created and saved: $KEY_PAIR_NAME.pem"
fi

# Create IAM role for EC2 instances
ROLE_NAME="$PROJECT_ID-ec2-role"
echo "👤 Creating IAM role for EC2 instances..."

# Create trust policy
cat > /tmp/ec2-trust-policy.json << 'EOF'
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "ec2.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOF

# Create IAM role
if aws iam get-role --role-name $ROLE_NAME > /dev/null 2>&1; then
    echo "⚠️  IAM role already exists, skipping creation"
else
    aws iam create-role \
        --role-name $ROLE_NAME \
        --assume-role-policy-document file:///tmp/ec2-trust-policy.json \
        --tags Key=Project,Value=$PROJECT_NAME
    
    echo "✅ IAM role created: $ROLE_NAME"
fi

# Create and attach S3 access policy
POLICY_NAME="$PROJECT_ID-s3-policy"
cat > /tmp/s3-access-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject",
                "s3:ListBucket",
                "s3:GetBucketLocation",
                "s3:ListAllMyBuckets"
            ],
            "Resource": [
                "arn:aws:s3:::$S3_BUCKET_NAME",
                "arn:aws:s3:::$S3_BUCKET_NAME/*",
                "arn:aws:s3:::*"
            ]
        },
        {
            "Effect": "Allow",
            "Action": [
                "ec2:DescribeVpcEndpoints",
                "ec2:DescribeRouteTables"
            ],
            "Resource": "*"
        }
    ]
}
EOF

if aws iam get-policy --policy-arn "arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):policy/$POLICY_NAME" > /dev/null 2>&1; then
    echo "⚠️  IAM policy already exists, skipping creation"
else
    aws iam create-policy \
        --policy-name $POLICY_NAME \
        --policy-document file:///tmp/s3-access-policy.json \
        --tags Key=Project,Value=$PROJECT_NAME
    
    echo "✅ IAM policy created: $POLICY_NAME"
fi

# Attach policy to role
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws iam attach-role-policy \
    --role-name $ROLE_NAME \
    --policy-arn "arn:aws:iam::$ACCOUNT_ID:policy/$POLICY_NAME"

# Create instance profile
INSTANCE_PROFILE_NAME="$PROJECT_ID-instance-profile"
if aws iam get-instance-profile --instance-profile-name $INSTANCE_PROFILE_NAME > /dev/null 2>&1; then
    echo "⚠️  Instance profile already exists, skipping creation"
else
    aws iam create-instance-profile \
        --instance-profile-name $INSTANCE_PROFILE_NAME \
        --tags Key=Project,Value=$PROJECT_NAME
    
    aws iam add-role-to-instance-profile \
        --instance-profile-name $INSTANCE_PROFILE_NAME \
        --role-name $ROLE_NAME
    
    echo "✅ Instance profile created: $INSTANCE_PROFILE_NAME"
    
    # Wait for instance profile to be ready
    echo "⏳ Waiting for instance profile to be ready..."
    sleep 10
fi

# Create user data script for instances
cat > /tmp/user-data.sh << 'EOF'
#!/bin/bash
yum update -y
yum install -y aws-cli jq htop

# Create test scripts
cat > /home/ec2-user/test-s3-endpoint.sh << 'SCRIPT'
#!/bin/bash
echo "=== S3 VPC Endpoint Test ==="
echo "Timestamp: $(date)"
echo "Instance ID: $(curl -s http://169.254.169.254/latest/meta-data/instance-id)"
echo "Private IP: $(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)"
echo ""

# Test S3 connectivity
echo "Testing S3 connectivity..."
aws s3 ls --region $(curl -s http://169.254.169.254/latest/meta-data/placement/region)

echo ""
echo "Testing bucket access..."
BUCKET_NAME=$(aws s3 ls | head -1 | awk '{print $3}')
if [ ! -z "$BUCKET_NAME" ]; then
    aws s3 ls s3://$BUCKET_NAME
    
    # Upload test file
    echo "Test from $(hostname) at $(date)" > /tmp/test-file.txt
    aws s3 cp /tmp/test-file.txt s3://$BUCKET_NAME/test-from-$(hostname).txt
    echo "Test file uploaded to s3://$BUCKET_NAME/test-from-$(hostname).txt"
fi
SCRIPT

chmod +x /home/ec2-user/test-s3-endpoint.sh
chown ec2-user:ec2-user /home/ec2-user/test-s3-endpoint.sh

# Create endpoint info script
cat > /home/ec2-user/check-endpoint.sh << 'SCRIPT'
#!/bin/bash
echo "=== VPC Endpoint Information ==="
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
aws ec2 describe-vpc-endpoints --region $REGION --query 'VpcEndpoints[?ServiceName==`com.amazonaws.'$REGION'.s3`]'
SCRIPT

chmod +x /home/ec2-user/check-endpoint.sh
chown ec2-user:ec2-user /home/ec2-user/check-endpoint.sh
EOF

# Deploy Bastion Host in Public Subnet
echo "🖥️ Deploying bastion host in public subnet..."
BASTION_INSTANCE_ID=$(aws ec2 run-instances \
    --image-id $AMI_ID \
    --count 1 \
    --instance-type t3.micro \
    --key-name $KEY_PAIR_NAME \
    --security-group-ids $BASTION_SG_ID \
    --subnet-id $PUBLIC_SUBNET_ID \
    --iam-instance-profile Name=$INSTANCE_PROFILE_NAME \
    --user-data file:///tmp/user-data.sh \
    --tag-specifications "ResourceType=instance,Tags=[
        {Key=Name,Value=$PROJECT_ID-bastion},
        {Key=Project,Value=$PROJECT_NAME},
        {Key=Type,Value=Bastion},
        {Key=Subnet,Value=Public}
    ]" \
    --region $AWS_REGION \
    --query 'Instances[0].InstanceId' \
    --output text)

echo "✅ Bastion host launched: $BASTION_INSTANCE_ID"

# Deploy Test Instance in Private Subnet
echo "🖥️ Deploying test instance in private subnet..."
PRIVATE_INSTANCE_ID=$(aws ec2 run-instances \
    --image-id $AMI_ID \
    --count 1 \
    --instance-type t3.micro \
    --key-name $KEY_PAIR_NAME \
    --security-group-ids $PRIVATE_SG_ID \
    --subnet-id $PRIVATE_SUBNET_ID \
    --iam-instance-profile Name=$INSTANCE_PROFILE_NAME \
    --user-data file:///tmp/user-data.sh \
    --tag-specifications "ResourceType=instance,Tags=[
        {Key=Name,Value=$PROJECT_ID-private-test},
        {Key=Project,Value=$PROJECT_NAME},
        {Key=Type,Value=TestInstance},
        {Key=Subnet,Value=Private}
    ]" \
    --region $AWS_REGION \
    --query 'Instances[0].InstanceId' \
    --output text)

echo "✅ Private test instance launched: $PRIVATE_INSTANCE_ID"

# Wait for instances to be running
echo "⏳ Waiting for instances to be running..."
aws ec2 wait instance-running \
    --instance-ids $BASTION_INSTANCE_ID $PRIVATE_INSTANCE_ID \
    --region $AWS_REGION

echo "✅ All instances are running"

# Get instance information
BASTION_PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids $BASTION_INSTANCE_ID \
    --region $AWS_REGION \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

BASTION_PRIVATE_IP=$(aws ec2 describe-instances \
    --instance-ids $BASTION_INSTANCE_ID \
    --region $AWS_REGION \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' \
    --output text)

PRIVATE_INSTANCE_IP=$(aws ec2 describe-instances \
    --instance-ids $PRIVATE_INSTANCE_ID \
    --region $AWS_REGION \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' \
    --output text)

# Update configuration with instance information
jq --arg bastion_id "$BASTION_INSTANCE_ID" \
   --arg bastion_public_ip "$BASTION_PUBLIC_IP" \
   --arg bastion_private_ip "$BASTION_PRIVATE_IP" \
   --arg private_id "$PRIVATE_INSTANCE_ID" \
   --arg private_ip "$PRIVATE_INSTANCE_IP" \
   --arg key_pair "$KEY_PAIR_NAME" \
   --arg iam_role "$ROLE_NAME" \
   '. + {
     bastion_instance_id: $bastion_id,
     bastion_public_ip: $bastion_public_ip,
     bastion_private_ip: $bastion_private_ip,
     private_instance_id: $private_id,
     private_instance_ip: $private_ip,
     key_pair_name: $key_pair,
     iam_role_name: $iam_role,
     instances_deployed: "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"
   }' \
   configs/vpc-parameters.json > configs/vpc-parameters.tmp && \
   mv configs/vpc-parameters.tmp configs/vpc-parameters.json

# Clean up temporary files
rm -f /tmp/ec2-trust-policy.json /tmp/s3-access-policy.json /tmp/user-data.sh

echo ""
echo "🎉 Test instances deployed successfully!"
echo "======================================="
echo ""
echo "📋 Instance Information:"
echo "   Bastion Host:"
echo "     Instance ID: $BASTION_INSTANCE_ID"
echo "     Public IP: $BASTION_PUBLIC_IP"
echo "     Private IP: $BASTION_PRIVATE_IP"
echo ""
echo "   Private Test Instance:"
echo "     Instance ID: $PRIVATE_INSTANCE_ID"
echo "     Private IP: $PRIVATE_INSTANCE_IP"
echo ""
echo "🔑 SSH Access:"
echo "   Key file: $KEY_PAIR_NAME.pem"
echo "   Bastion: ssh -i $KEY_PAIR_NAME.pem ec2-user@$BASTION_PUBLIC_IP"
echo "   Private: ssh -i $KEY_PAIR_NAME.pem -J ec2-user@$BASTION_PUBLIC_IP ec2-user@$PRIVATE_INSTANCE_IP"
echo ""
echo "🧪 Test Scripts (available on instances):"
echo "   ~/test-s3-endpoint.sh - Test S3 connectivity"
echo "   ~/check-endpoint.sh - Check VPC endpoint info"
echo ""
echo "⏳ Note: Wait 2-3 minutes for instances to fully initialize before testing"
echo ""
echo "➡️  Next step: Run ./scripts/04-test-s3-connectivity.sh"
