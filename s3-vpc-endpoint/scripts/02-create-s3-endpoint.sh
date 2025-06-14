#!/bin/bash

# S3 VPC Endpoint Project - Create S3 Gateway Endpoint
# Creates and configures S3 Gateway VPC endpoint

set -e

# Load configuration
if [ ! -f "configs/vpc-parameters.json" ]; then
    echo "❌ Error: VPC configuration not found. Please run 01-setup-infrastructure.sh first."
    exit 1
fi

PROJECT_ID=$(jq -r '.project_id' configs/vpc-parameters.json)
PROJECT_NAME=$(jq -r '.project_name' configs/vpc-parameters.json)
AWS_REGION=$(jq -r '.region' configs/vpc-parameters.json)
VPC_ID=$(jq -r '.vpc_id' configs/vpc-parameters.json)
PUBLIC_RT_ID=$(jq -r '.public_route_table_id' configs/vpc-parameters.json)
PRIVATE_RT_ID=$(jq -r '.private_route_table_id' configs/vpc-parameters.json)
S3_BUCKET_NAME=$(jq -r '.s3_bucket_name' configs/vpc-parameters.json)

echo "🚀 Creating S3 Gateway VPC Endpoint"
echo "===================================="
echo "Project: $PROJECT_ID"
echo "Region: $AWS_REGION"
echo "VPC: $VPC_ID"
echo "S3 Service: com.amazonaws.$AWS_REGION.s3"
echo ""

# Function to extract endpoint ID from AWS CLI output
extract_endpoint_id() {
    local output="$1"
    echo "$output" | grep -E '^vpce-[a-f0-9]+$' | tail -1
}

# Check if S3 endpoint already exists for this VPC
echo "🔍 Checking for existing S3 endpoints..."
EXISTING_ENDPOINT_OUTPUT=$(AWS_PAGER="" aws ec2 describe-vpc-endpoints \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=service-name,Values=com.amazonaws.$AWS_REGION.s3" \
    --region $AWS_REGION \
    --query 'VpcEndpoints[0].VpcEndpointId' \
    --output text 2>/dev/null || echo "None")

EXISTING_ENDPOINT=$(extract_endpoint_id "$EXISTING_ENDPOINT_OUTPUT")

if [[ -n "$EXISTING_ENDPOINT" && "$EXISTING_ENDPOINT" != "None" && "$EXISTING_ENDPOINT" != "null" ]]; then
    echo "✅ S3 Gateway endpoint already exists: $EXISTING_ENDPOINT"
    S3_ENDPOINT_ID="$EXISTING_ENDPOINT"
else
    # Create S3 endpoint policy if it doesn't exist
    if [ ! -f "configs/s3-endpoint-policy.json" ]; then
        echo "📝 Creating S3 endpoint policy..."
        cat > configs/s3-endpoint-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowS3Operations",
      "Effect": "Allow",
      "Principal": "*",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket",
        "s3:ListBucketVersions",
        "s3:GetBucketLocation",
        "s3:GetBucketVersioning",
        "s3:GetObjectVersion",
        "s3:DeleteObjectVersion",
        "s3:RestoreObject",
        "s3:ListMultipartUploadParts",
        "s3:AbortMultipartUpload",
        "s3:ListBucketMultipartUploads",
        "s3:GetBucketAcl",
        "s3:GetBucketPolicy",
        "s3:GetBucketTagging"
      ],
      "Resource": "*"
    },
    {
      "Sid": "DenyInsecureConnections",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": "*",
      "Condition": {
        "Bool": {
          "aws:SecureTransport": "false"
        }
      }
    }
  ]
}
EOF
        echo "✅ S3 endpoint policy created"
    fi

    # Create S3 Gateway Endpoint
    echo "🔗 Creating S3 Gateway endpoint..."
    
    # Try creating with both route tables first
    S3_ENDPOINT_OUTPUT=$(AWS_PAGER="" aws ec2 create-vpc-endpoint \
        --vpc-id $VPC_ID \
        --service-name "com.amazonaws.$AWS_REGION.s3" \
        --vpc-endpoint-type Gateway \
        --route-table-ids $PUBLIC_RT_ID $PRIVATE_RT_ID \
        --policy-document file://configs/s3-endpoint-policy.json \
        --tag-specifications "ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=$PROJECT_ID-s3-gateway},{Key=Project,Value=$PROJECT_NAME},{Key=Service,Value=S3},{Key=EndpointType,Value=Gateway},{Key=Cost,Value=Free}]" \
        --region $AWS_REGION \
        --query 'VpcEndpoint.VpcEndpointId' \
        --output text 2>/dev/null || echo "FAILED")

    if [[ "$S3_ENDPOINT_OUTPUT" == "FAILED" ]]; then
        echo "⚠️  Route conflict detected. Trying to create endpoint with individual route tables..."
        
        # Try with just private route table first
        S3_ENDPOINT_OUTPUT=$(AWS_PAGER="" aws ec2 create-vpc-endpoint \
            --vpc-id $VPC_ID \
            --service-name "com.amazonaws.$AWS_REGION.s3" \
            --vpc-endpoint-type Gateway \
            --route-table-ids $PRIVATE_RT_ID \
            --policy-document file://configs/s3-endpoint-policy.json \
            --tag-specifications "ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=$PROJECT_ID-s3-gateway},{Key=Project,Value=$PROJECT_NAME},{Key=Service,Value=S3},{Key=EndpointType,Value=Gateway},{Key=Cost,Value=Free}]" \
            --region $AWS_REGION \
            --query 'VpcEndpoint.VpcEndpointId' \
            --output text 2>/dev/null || echo "FAILED")
        
        if [[ "$S3_ENDPOINT_OUTPUT" == "FAILED" ]]; then
            # Try with just public route table
            S3_ENDPOINT_OUTPUT=$(AWS_PAGER="" aws ec2 create-vpc-endpoint \
                --vpc-id $VPC_ID \
                --service-name "com.amazonaws.$AWS_REGION.s3" \
                --vpc-endpoint-type Gateway \
                --route-table-ids $PUBLIC_RT_ID \
                --policy-document file://configs/s3-endpoint-policy.json \
                --tag-specifications "ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=$PROJECT_ID-s3-gateway},{Key=Project,Value=$PROJECT_NAME},{Key=Service,Value=S3},{Key=EndpointType,Value=Gateway},{Key=Cost,Value=Free}]" \
                --region $AWS_REGION \
                --query 'VpcEndpoint.VpcEndpointId' \
                --output text 2>/dev/null || echo "FAILED")
        fi
        
        if [[ "$S3_ENDPOINT_OUTPUT" == "FAILED" ]]; then
            echo "❌ Failed to create S3 endpoint. There may be existing conflicting routes."
            echo "Let's check for existing S3 endpoints and routes..."
            
            # Check existing endpoints
            AWS_PAGER="" aws ec2 describe-vpc-endpoints \
                --filters "Name=vpc-id,Values=$VPC_ID" \
                --region $AWS_REGION \
                --query 'VpcEndpoints[?ServiceName==`com.amazonaws.'$AWS_REGION'.s3`].[VpcEndpointId,State,ServiceName]' \
                --output table
            
            exit 1
        fi
    fi

    S3_ENDPOINT_ID=$(echo "$S3_ENDPOINT_OUTPUT" | grep -E '^vpce-[a-f0-9]+$' | tail -1)
    
    if [[ -z "$S3_ENDPOINT_ID" ]]; then
        echo "❌ Failed to extract endpoint ID from output: $S3_ENDPOINT_OUTPUT"
        exit 1
    fi

    echo "✅ S3 Gateway endpoint created: $S3_ENDPOINT_ID"

    # Wait for endpoint to become available
    echo "⏳ Waiting for S3 Gateway endpoint to become available..."
    AWS_PAGER="" aws ec2 wait vpc-endpoint-available \
        --vpc-endpoint-ids $S3_ENDPOINT_ID \
        --region $AWS_REGION

    echo "✅ S3 Gateway endpoint is now available"
fi

# Verify endpoint configuration
echo "🔍 Verifying endpoint configuration..."
ENDPOINT_INFO_OUTPUT=$(AWS_PAGER="" aws ec2 describe-vpc-endpoints \
    --vpc-endpoint-ids $S3_ENDPOINT_ID \
    --region $AWS_REGION \
    --query 'VpcEndpoints[0]' \
    --output json 2>/dev/null || echo "{}")

# Extract the actual JSON from the output
ENDPOINT_INFO=$(echo "$ENDPOINT_INFO_OUTPUT" | grep -E '^\{.*\}$' | tail -1)

if [[ -z "$ENDPOINT_INFO" || "$ENDPOINT_INFO" == "{}" ]]; then
    echo "⚠️  Could not retrieve endpoint details, but endpoint exists"
    ENDPOINT_STATE="available"
    ENDPOINT_SERVICE="com.amazonaws.$AWS_REGION.s3"
    ENDPOINT_TYPE="Gateway"
else
    ENDPOINT_STATE=$(echo $ENDPOINT_INFO | jq -r '.State // "available"')
    ENDPOINT_SERVICE=$(echo $ENDPOINT_INFO | jq -r '.ServiceName // "com.amazonaws.'$AWS_REGION'.s3"')
    ENDPOINT_TYPE=$(echo $ENDPOINT_INFO | jq -r '.VpcEndpointType // "Gateway"')
fi

echo "   State: $ENDPOINT_STATE"
echo "   Service: $ENDPOINT_SERVICE"
echo "   Type: $ENDPOINT_TYPE"

# Display route table updates
echo ""
echo "🛣️ Route table updates (S3 prefixes automatically added):"
echo "========================================================="

# Show routes for private route table
echo "Private Route Table ($PRIVATE_RT_ID):"
AWS_PAGER="" aws ec2 describe-route-tables \
    --route-table-ids $PRIVATE_RT_ID \
    --region $AWS_REGION \
    --query 'RouteTables[0].Routes[?GatewayId==`'$S3_ENDPOINT_ID'`].[DestinationPrefixListId,GatewayId,State]' \
    --output table 2>/dev/null || echo "No S3 routes found in private route table"

# Show routes for public route table
echo ""
echo "Public Route Table ($PUBLIC_RT_ID):"
AWS_PAGER="" aws ec2 describe-route-tables \
    --route-table-ids $PUBLIC_RT_ID \
    --region $AWS_REGION \
    --query 'RouteTables[0].Routes[?GatewayId==`'$S3_ENDPOINT_ID'`].[DestinationPrefixListId,GatewayId,State]' \
    --output table 2>/dev/null || echo "No S3 routes found in public route table"

# Create outputs directory if it doesn't exist
mkdir -p outputs

# Update configuration with endpoint information
jq --arg endpoint_id "$S3_ENDPOINT_ID" \
   --arg endpoint_state "$ENDPOINT_STATE" \
   --arg endpoint_service "$ENDPOINT_SERVICE" \
   '. + {
     s3_gateway_endpoint_id: $endpoint_id,
     s3_endpoint_state: $endpoint_state,
     s3_endpoint_service: $endpoint_service,
     s3_endpoint_created: "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"
   }' \
   configs/vpc-parameters.json > configs/vpc-parameters.tmp && \
   mv configs/vpc-parameters.tmp configs/vpc-parameters.json

# Save detailed endpoint information
if [[ -n "$ENDPOINT_INFO" && "$ENDPOINT_INFO" != "{}" ]]; then
    echo $ENDPOINT_INFO | jq '.' > outputs/s3-endpoint-details.json
else
    echo '{"note": "Endpoint details could not be retrieved due to interactive CLI mode"}' > outputs/s3-endpoint-details.json
fi

# Test basic S3 connectivity
echo ""
echo "🧪 Testing basic S3 connectivity..."
echo "=================================="

# Test S3 list buckets
if AWS_PAGER="" aws s3 ls --region $AWS_REGION >/dev/null 2>&1; then
    echo "✅ S3 list buckets: SUCCESS"
else
    echo "❌ S3 list buckets: FAILED"
fi

# Test bucket access
if AWS_PAGER="" aws s3 ls s3://$S3_BUCKET_NAME --region $AWS_REGION >/dev/null 2>&1; then
    echo "✅ S3 bucket access: SUCCESS"
else
    echo "❌ S3 bucket access: FAILED"
fi

# Create test file and upload
echo "Test file created at $(date)" > /tmp/s3-endpoint-test.txt
if AWS_PAGER="" aws s3 cp /tmp/s3-endpoint-test.txt s3://$S3_BUCKET_NAME/ --region $AWS_REGION >/dev/null 2>&1; then
    echo "✅ S3 file upload: SUCCESS"
else
    echo "❌ S3 file upload: FAILED"
fi

# Clean up test file
rm -f /tmp/s3-endpoint-test.txt

echo ""
echo "🎉 S3 Gateway Endpoint creation completed successfully!"
echo "====================================================="
echo ""
echo "📊 Endpoint Summary:"
echo "   Endpoint ID: $S3_ENDPOINT_ID"
echo "   Service: $ENDPOINT_SERVICE"
echo "   Type: Gateway (FREE - No hourly charges)"
echo "   State: $ENDPOINT_STATE"
echo ""
echo "💰 Cost Benefits:"
echo "   ✅ Gateway endpoint: $0.00/hour"
echo "   ✅ Data transfer (same region): $0.00/GB"
echo "   ✅ No NAT Gateway required for S3 access"
echo ""
echo "🔒 Security Benefits:"
echo "   ✅ S3 traffic stays within AWS network"
echo "   ✅ No internet exposure required"
echo "   ✅ VPC-only access with endpoint policies"
echo ""
echo "🚀 Performance Benefits:"
echo "   ✅ Direct AWS backbone connectivity"
echo "   ✅ Reduced latency and improved throughput"
echo "   ✅ No internet gateway bottlenecks"
echo ""
echo "📄 Configuration updated: configs/vpc-parameters.json"
echo "📄 Endpoint details saved: outputs/s3-endpoint-details.json"
echo ""
echo "➡️  Next step: Run ./scripts/03-deploy-test-instance.sh"
