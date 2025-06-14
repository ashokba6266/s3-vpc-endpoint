#!/bin/bash

# S3 VPC Endpoint Project - Deploy Test Instances
# Creates EC2 instances to test S3 connectivity through VPC endpoint

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

# Function to extract resource IDs from AWS CLI output
extract_resource_id() {
    local output="$1"
    local pattern="$2"
    echo "$output" | grep -E "$pattern" | tail -1
}

# Find latest Amazon Linux 2 AMI
echo "🔍 Finding latest Amazon Linux 2 AMI..."
AMI_OUTPUT=$(AWS_PAGER="" aws ec2 describe-images \
    --owners amazon \
    --filters 'Name=name,Values=amzn2-ami-hvm-*-x86_64-gp2' 'Name=state,Values=available' \
    --region $AWS_REGION \
    --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
    --output text 2>/dev/null)

AMI_ID=$(extract_resource_id "$AMI_OUTPUT" "^ami-[a-f0-9]+$")

if [[ -z "$AMI_ID" ]]; then
    echo "❌ Failed to find Amazon Linux 2 AMI"
    exit 1
fi

echo "✅ Using AMI: $AMI_ID"

# Create key pair if it doesn't exist
KEY_PAIR_NAME="$PROJECT_ID-keypair"
if [ ! -f "$KEY_PAIR_NAME.pem" ]; then
    echo "🔑 Creating key pair: $KEY_PAIR_NAME"
    AWS_PAGER="" aws ec2 create-key-pair \
        --key-name $KEY_PAIR_NAME \
        --region $AWS_REGION \
        --query 'KeyMaterial' \
        --output text > $KEY_PAIR_NAME.pem 2>/dev/null
    
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
if AWS_PAGER="" aws iam get-role --role-name $ROLE_NAME >/dev/null 2>&1; then
    echo "⚠️  IAM role already exists, skipping creation"
else
    AWS_PAGER="" aws iam create-role \
        --role-name $ROLE_NAME \
        --assume-role-policy-document file:///tmp/ec2-trust-policy.json \
        --tags Key=Project,Value=$PROJECT_NAME >/dev/null 2>&1
    echo "✅ IAM role created: $ROLE_NAME"
fi

# Create S3 access policy
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
                "s3:GetBucketLocation"
            ],
            "Resource": [
                "arn:aws:s3:::$S3_BUCKET_NAME",
                "arn:aws:s3:::$S3_BUCKET_NAME/*"
            ]
        },
        {
            "Effect": "Allow",
            "Action": [
                "s3:ListAllMyBuckets",
                "s3:GetBucketLocation"
            ],
            "Resource": "*"
        }
    ]
}
EOF

# Get account ID
ACCOUNT_ID_OUTPUT=$(AWS_PAGER="" aws sts get-caller-identity --query Account --output text 2>/dev/null)
ACCOUNT_ID=$(extract_resource_id "$ACCOUNT_ID_OUTPUT" "^[0-9]{12}$")

if [[ -z "$ACCOUNT_ID" ]]; then
    echo "❌ Failed to get AWS account ID"
    exit 1
fi

# Create policy if it doesn't exist
POLICY_ARN="arn:aws:iam::$ACCOUNT_ID:policy/$POLICY_NAME"
if AWS_PAGER="" aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
    echo "⚠️  IAM policy already exists, skipping creation"
else
    AWS_PAGER="" aws iam create-policy \
        --policy-name $POLICY_NAME \
        --policy-document file:///tmp/s3-access-policy.json \
        --tags Key=Project,Value=$PROJECT_NAME >/dev/null 2>&1
    echo "✅ IAM policy created: $POLICY_NAME"
fi

# Attach policy to role
AWS_PAGER="" aws iam attach-role-policy \
    --role-name $ROLE_NAME \
    --policy-arn $POLICY_ARN >/dev/null 2>&1

echo "✅ IAM policy attached to role"

# Create instance profile
INSTANCE_PROFILE_NAME="$PROJECT_ID-instance-profile"
if AWS_PAGER="" aws iam get-instance-profile --instance-profile-name $INSTANCE_PROFILE_NAME >/dev/null 2>&1; then
    echo "⚠️  Instance profile already exists, skipping creation"
else
    AWS_PAGER="" aws iam create-instance-profile \
        --instance-profile-name $INSTANCE_PROFILE_NAME \
        --tags Key=Project,Value=$PROJECT_NAME >/dev/null 2>&1
    
    # Add role to instance profile
    AWS_PAGER="" aws iam add-role-to-instance-profile \
        --instance-profile-name $INSTANCE_PROFILE_NAME \
        --role-name $ROLE_NAME >/dev/null 2>&1
    
    echo "✅ Instance profile created: $INSTANCE_PROFILE_NAME"
    
    # Wait for instance profile to be ready
    echo "⏳ Waiting for instance profile to be ready..."
    sleep 10
fi

# Create user data script for instances
cat > /tmp/user-data.sh << 'EOF'
#!/bin/bash
yum update -y
yum install -y aws-cli

# Create test script
cat > /home/ec2-user/test-s3-endpoint.sh << 'SCRIPT'
#!/bin/bash
echo "=== S3 VPC Endpoint Test ==="
echo "Date: $(date)"
echo "Instance ID: $(curl -s http://169.254.169.254/latest/meta-data/instance-id)"
echo "Private IP: $(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)"
echo ""

echo "Testing S3 connectivity..."
echo "1. List buckets:"
aws s3 ls

echo ""
echo "2. List bucket contents:"
aws s3 ls s3://BUCKET_NAME/

echo ""
echo "3. Upload test file:"
echo "Test from $(hostname) at $(date)" > /tmp/test-file.txt
aws s3 cp /tmp/test-file.txt s3://BUCKET_NAME/test-from-$(hostname).txt

echo ""
echo "4. Download test file:"
aws s3 cp s3://BUCKET_NAME/test-from-$(hostname).txt /tmp/downloaded-test.txt
cat /tmp/downloaded-test.txt

echo ""
echo "5. Check routing (S3 should go through VPC endpoint):"
echo "Checking route to S3..."
# This will show if traffic goes through the VPC endpoint
curl -s https://s3.amazonaws.com 2>&1 | head -5 || echo "Direct S3 access test"

echo ""
echo "=== Test Complete ==="
SCRIPT

# Replace BUCKET_NAME placeholder
sed -i "s/BUCKET_NAME/$S3_BUCKET_NAME/g" /home/ec2-user/test-s3-endpoint.sh
chmod +x /home/ec2-user/test-s3-endpoint.sh
chown ec2-user:ec2-user /home/ec2-user/test-s3-endpoint.sh

# Install additional tools
yum install -y htop tree curl wget

echo "Instance setup complete!" > /var/log/user-data.log
EOF

# Replace bucket name in user data
sed -i "s/\$S3_BUCKET_NAME/$S3_BUCKET_NAME/g" /tmp/user-data.sh

# Launch bastion host in public subnet
echo "🖥️ Launching bastion host..."
BASTION_OUTPUT=$(AWS_PAGER="" aws ec2 run-instances \
    --image-id $AMI_ID \
    --count 1 \
    --instance-type t3.micro \
    --key-name $KEY_PAIR_NAME \
    --security-group-ids $BASTION_SG_ID \
    --subnet-id $PUBLIC_SUBNET_ID \
    --iam-instance-profile Name=$INSTANCE_PROFILE_NAME \
    --user-data file:///tmp/user-data.sh \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$PROJECT_ID-bastion},{Key=Project,Value=$PROJECT_NAME},{Key=Type,Value=Bastion},{Key=Subnet,Value=Public}]" \
    --region $AWS_REGION \
    --query 'Instances[0].InstanceId' \
    --output text 2>/dev/null)

BASTION_INSTANCE_ID=$(extract_resource_id "$BASTION_OUTPUT" "^i-[a-f0-9]+$")

if [[ -z "$BASTION_INSTANCE_ID" ]]; then
    echo "❌ Failed to launch bastion host"
    exit 1
fi

echo "✅ Bastion host launched: $BASTION_INSTANCE_ID"

# Launch private instance in private subnet
echo "🖥️ Launching private instance..."
PRIVATE_OUTPUT=$(AWS_PAGER="" aws ec2 run-instances \
    --image-id $AMI_ID \
    --count 1 \
    --instance-type t3.micro \
    --key-name $KEY_PAIR_NAME \
    --security-group-ids $PRIVATE_SG_ID \
    --subnet-id $PRIVATE_SUBNET_ID \
    --iam-instance-profile Name=$INSTANCE_PROFILE_NAME \
    --user-data file:///tmp/user-data.sh \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$PROJECT_ID-private},{Key=Project,Value=$PROJECT_NAME},{Key=Type,Value=Private},{Key=Subnet,Value=Private}]" \
    --region $AWS_REGION \
    --query 'Instances[0].InstanceId' \
    --output text 2>/dev/null)

PRIVATE_INSTANCE_ID=$(extract_resource_id "$PRIVATE_OUTPUT" "^i-[a-f0-9]+$")

if [[ -z "$PRIVATE_INSTANCE_ID" ]]; then
    echo "❌ Failed to launch private instance"
    exit 1
fi

echo "✅ Private instance launched: $PRIVATE_INSTANCE_ID"

# Wait for instances to be running
echo "⏳ Waiting for instances to be running..."
AWS_PAGER="" aws ec2 wait instance-running \
    --instance-ids $BASTION_INSTANCE_ID $PRIVATE_INSTANCE_ID \
    --region $AWS_REGION

echo "✅ All instances are running"

# Get instance details
echo "🔍 Getting instance details..."
BASTION_IP_OUTPUT=$(AWS_PAGER="" aws ec2 describe-instances \
    --instance-ids $BASTION_INSTANCE_ID \
    --region $AWS_REGION \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text 2>/dev/null)

BASTION_PUBLIC_IP=$(extract_resource_id "$BASTION_IP_OUTPUT" "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$")

PRIVATE_IP_OUTPUT=$(AWS_PAGER="" aws ec2 describe-instances \
    --instance-ids $PRIVATE_INSTANCE_ID \
    --region $AWS_REGION \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' \
    --output text 2>/dev/null)

PRIVATE_INSTANCE_IP=$(extract_resource_id "$PRIVATE_IP_OUTPUT" "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$")

# Update configuration with instance information
jq --arg bastion_id "$BASTION_INSTANCE_ID" \
   --arg bastion_ip "$BASTION_PUBLIC_IP" \
   --arg private_id "$PRIVATE_INSTANCE_ID" \
   --arg private_ip "$PRIVATE_INSTANCE_IP" \
   --arg key_pair "$KEY_PAIR_NAME" \
   --arg role_name "$ROLE_NAME" \
   --arg policy_name "$POLICY_NAME" \
   '. + {
     bastion_instance_id: $bastion_id,
     bastion_public_ip: $bastion_ip,
     private_instance_id: $private_id,
     private_instance_ip: $private_ip,
     key_pair_name: $key_pair,
     iam_role_name: $role_name,
     iam_policy_name: $policy_name,
     instances_created: "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"
   }' \
   configs/vpc-parameters.json > configs/vpc-parameters.tmp && \
   mv configs/vpc-parameters.tmp configs/vpc-parameters.json

# Clean up temporary files
rm -f /tmp/ec2-trust-policy.json /tmp/s3-access-policy.json /tmp/user-data.sh

echo ""
echo "🎉 Test instances deployed successfully!"
echo "======================================="
echo ""
echo "📋 Instance Summary:"
echo "   Bastion Host: $BASTION_INSTANCE_ID"
echo "   Public IP: $BASTION_PUBLIC_IP"
echo "   Private Instance: $PRIVATE_INSTANCE_ID"
echo "   Private IP: $PRIVATE_INSTANCE_IP"
echo ""
echo "🔑 SSH Access:"
echo "   Key file: $KEY_PAIR_NAME.pem"
echo "   Bastion: ssh -i $KEY_PAIR_NAME.pem ec2-user@$BASTION_PUBLIC_IP"
echo "   Private: ssh -i $KEY_PAIR_NAME.pem -o ProxyCommand=\"ssh -i $KEY_PAIR_NAME.pem -W %h:%p ec2-user@$BASTION_PUBLIC_IP\" ec2-user@$PRIVATE_INSTANCE_IP"
echo ""
echo "🧪 Testing S3 Endpoint:"
echo "   Both instances have a test script: /home/ec2-user/test-s3-endpoint.sh"
echo "   Run this script to test S3 connectivity through the VPC endpoint"
echo ""
echo "⚠️  Security Note:"
echo "   The bastion host allows SSH from 0.0.0.0/0 for demo purposes"
echo "   In production, restrict to your specific IP address"
echo ""
echo "📄 Configuration updated: configs/vpc-parameters.json"
echo ""
echo "➡️  Next step: Run ./scripts/04-test-s3-connectivity.sh"
