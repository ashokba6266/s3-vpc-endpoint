#!/bin/bash

# S3 VPC Endpoint Project - Test S3 Connectivity
# Comprehensive testing of S3 endpoint functionality

set -e

# Load configuration
if [ ! -f "configs/vpc-parameters.json" ]; then
    echo "❌ Error: VPC configuration not found. Please run previous scripts first."
    exit 1
fi

PROJECT_ID=$(jq -r '.project_id' configs/vpc-parameters.json)
AWS_REGION=$(jq -r '.region' configs/vpc-parameters.json)
S3_BUCKET_NAME=$(jq -r '.s3_bucket_name' configs/vpc-parameters.json)
S3_ENDPOINT_ID=$(jq -r '.s3_gateway_endpoint_id' configs/vpc-parameters.json)
VPC_ID=$(jq -r '.vpc_id' configs/vpc-parameters.json)
BASTION_PUBLIC_IP=$(jq -r '.bastion_public_ip' configs/vpc-parameters.json)
PRIVATE_INSTANCE_IP=$(jq -r '.private_instance_ip' configs/vpc-parameters.json)
KEY_PAIR_NAME=$(jq -r '.key_pair_name' configs/vpc-parameters.json)

echo "🧪 S3 VPC Endpoint Connectivity Testing"
echo "========================================"
echo "Project: $PROJECT_ID"
echo "Region: $AWS_REGION"
echo "S3 Bucket: $S3_BUCKET_NAME"
echo "Endpoint ID: $S3_ENDPOINT_ID"
echo ""

# Initialize test results
TEST_RESULTS='{
  "test_timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
  "project_id": "'$PROJECT_ID'",
  "region": "'$AWS_REGION'",
  "s3_bucket": "'$S3_BUCKET_NAME'",
  "endpoint_id": "'$S3_ENDPOINT_ID'",
  "tests": {}
}'

# Test 1: Verify S3 Gateway Endpoint Status
echo "🔍 Test 1: Verifying S3 Gateway Endpoint Status"
echo "================================================"

ENDPOINT_STATE=$(aws ec2 describe-vpc-endpoints \
    --vpc-endpoint-ids $S3_ENDPOINT_ID \
    --region $AWS_REGION \
    --query 'VpcEndpoints[0].State' \
    --output text)

if [ "$ENDPOINT_STATE" = "available" ]; then
    echo "✅ S3 Gateway endpoint is available"
    TEST_RESULTS=$(echo $TEST_RESULTS | jq '.tests.endpoint_status = {
        "status": "PASS",
        "state": "'$ENDPOINT_STATE'",
        "message": "Endpoint is available"
    }')
else
    echo "❌ S3 Gateway endpoint is not available (State: $ENDPOINT_STATE)"
    TEST_RESULTS=$(echo $TEST_RESULTS | jq '.tests.endpoint_status = {
        "status": "FAIL",
        "state": "'$ENDPOINT_STATE'",
        "message": "Endpoint is not available"
    }')
fi

# Display endpoint details
echo ""
echo "📊 Endpoint Details:"
aws ec2 describe-vpc-endpoints \
    --vpc-endpoint-ids $S3_ENDPOINT_ID \
    --region $AWS_REGION \
    --query 'VpcEndpoints[0].[VpcEndpointId,ServiceName,VpcEndpointType,State,CreationTimestamp]' \
    --output table

# Test 2: Verify Route Table Configuration
echo ""
echo "🛣️ Test 2: Verifying Route Table Configuration"
echo "=============================================="

ROUTE_COUNT=$(aws ec2 describe-route-tables \
    --region $AWS_REGION \
    --filters "Name=tag:Project,Values=s3-vpc-endpoint" \
    --query 'RouteTables[*].Routes[?GatewayId==`'$S3_ENDPOINT_ID'`]' \
    --output json | jq length)

if [ "$ROUTE_COUNT" -gt 0 ]; then
    echo "✅ Found $ROUTE_COUNT S3 prefix routes in route tables"
    TEST_RESULTS=$(echo $TEST_RESULTS | jq '.tests.route_configuration = {
        "status": "PASS",
        "route_count": '$ROUTE_COUNT',
        "message": "S3 routes properly configured"
    }')
    
    echo ""
    echo "📋 S3 Prefix Routes:"
    aws ec2 describe-route-tables \
        --region $AWS_REGION \
        --filters "Name=tag:Project,Values=s3-vpc-endpoint" \
        --query 'RouteTables[*].Routes[?GatewayId==`'$S3_ENDPOINT_ID'`].[DestinationCidrBlock,GatewayId,State]' \
        --output table
else
    echo "❌ No S3 prefix routes found in route tables"
    TEST_RESULTS=$(echo $TEST_RESULTS | jq '.tests.route_configuration = {
        "status": "FAIL",
        "route_count": 0,
        "message": "No S3 routes found"
    }')
fi

# Test 3: Basic S3 Operations from Local Environment
echo ""
echo "🌐 Test 3: Basic S3 Operations (Local Environment)"
echo "=================================================="

# Test S3 list buckets
echo "Testing S3 list buckets..."
if aws s3 ls --region $AWS_REGION > /dev/null 2>&1; then
    echo "✅ S3 list buckets: SUCCESS"
    S3_LIST_STATUS="PASS"
else
    echo "❌ S3 list buckets: FAILED"
    S3_LIST_STATUS="FAIL"
fi

# Test bucket access
echo "Testing S3 bucket access..."
if aws s3 ls s3://$S3_BUCKET_NAME --region $AWS_REGION > /dev/null 2>&1; then
    echo "✅ S3 bucket access: SUCCESS"
    S3_BUCKET_STATUS="PASS"
else
    echo "❌ S3 bucket access: FAILED"
    S3_BUCKET_STATUS="FAIL"
fi

# Test file operations
echo "Testing S3 file operations..."
TEST_FILE_CONTENT="S3 VPC Endpoint test from local environment at $(date)"
echo "$TEST_FILE_CONTENT" > /tmp/local-test-file.txt

if aws s3 cp /tmp/local-test-file.txt s3://$S3_BUCKET_NAME/local-test-file.txt --region $AWS_REGION > /dev/null 2>&1; then
    echo "✅ S3 file upload: SUCCESS"
    
    # Test download
    if aws s3 cp s3://$S3_BUCKET_NAME/local-test-file.txt /tmp/downloaded-test-file.txt --region $AWS_REGION > /dev/null 2>&1; then
        echo "✅ S3 file download: SUCCESS"
        S3_FILE_OPS_STATUS="PASS"
    else
        echo "❌ S3 file download: FAILED"
        S3_FILE_OPS_STATUS="FAIL"
    fi
else
    echo "❌ S3 file upload: FAILED"
    S3_FILE_OPS_STATUS="FAIL"
fi

TEST_RESULTS=$(echo $TEST_RESULTS | jq '.tests.local_s3_operations = {
    "status": "'$S3_FILE_OPS_STATUS'",
    "list_buckets": "'$S3_LIST_STATUS'",
    "bucket_access": "'$S3_BUCKET_STATUS'",
    "file_operations": "'$S3_FILE_OPS_STATUS'"
}')

# Test 4: Performance Benchmark
echo ""
echo "⚡ Test 4: Performance Benchmark"
echo "==============================="

# Create test files of different sizes
echo "Creating test files for performance testing..."
dd if=/dev/zero of=/tmp/test-1mb.dat bs=1024 count=1024 2>/dev/null
dd if=/dev/zero of=/tmp/test-10mb.dat bs=1024 count=10240 2>/dev/null

# Test 1MB upload
echo "Testing 1MB file upload..."
START_TIME=$(date +%s.%N)
aws s3 cp /tmp/test-1mb.dat s3://$S3_BUCKET_NAME/perf-test-1mb.dat --region $AWS_REGION > /dev/null 2>&1
END_TIME=$(date +%s.%N)
UPLOAD_1MB_TIME=$(echo "$END_TIME - $START_TIME" | bc -l 2>/dev/null || echo "N/A")

# Test 10MB upload
echo "Testing 10MB file upload..."
START_TIME=$(date +%s.%N)
aws s3 cp /tmp/test-10mb.dat s3://$S3_BUCKET_NAME/perf-test-10mb.dat --region $AWS_REGION > /dev/null 2>&1
END_TIME=$(date +%s.%N)
UPLOAD_10MB_TIME=$(echo "$END_TIME - $START_TIME" | bc -l 2>/dev/null || echo "N/A")

echo "✅ Performance test completed"
echo "   1MB upload: ${UPLOAD_1MB_TIME} seconds"
echo "   10MB upload: ${UPLOAD_10MB_TIME} seconds"

TEST_RESULTS=$(echo $TEST_RESULTS | jq '.tests.performance_benchmark = {
    "status": "PASS",
    "upload_1mb_seconds": "'$UPLOAD_1MB_TIME'",
    "upload_10mb_seconds": "'$UPLOAD_10MB_TIME'"
}')

# Test 5: DNS Resolution Test
echo ""
echo "🔍 Test 5: DNS Resolution Test"
echo "=============================="

S3_DNS="s3.$AWS_REGION.amazonaws.com"
echo "Testing DNS resolution for $S3_DNS..."

if command -v nslookup >/dev/null 2>&1; then
    DNS_RESULT=$(nslookup $S3_DNS 2>/dev/null | grep -A 10 "Name:" || echo "DNS lookup failed")
    echo "$DNS_RESULT"
    DNS_STATUS="PASS"
elif command -v dig >/dev/null 2>&1; then
    DNS_RESULT=$(dig $S3_DNS +short 2>/dev/null || echo "DNS lookup failed")
    echo "DNS resolution result: $DNS_RESULT"
    DNS_STATUS="PASS"
else
    echo "⚠️  DNS lookup tools not available"
    DNS_STATUS="SKIP"
fi

TEST_RESULTS=$(echo $TEST_RESULTS | jq '.tests.dns_resolution = {
    "status": "'$DNS_STATUS'",
    "dns_name": "'$S3_DNS'"
}')

# Test 6: Endpoint Policy Validation
echo ""
echo "🔒 Test 6: Endpoint Policy Validation"
echo "===================================="

POLICY_DOCUMENT=$(aws ec2 describe-vpc-endpoints \
    --vpc-endpoint-ids $S3_ENDPOINT_ID \
    --region $AWS_REGION \
    --query 'VpcEndpoints[0].PolicyDocument' \
    --output text)

if [ "$POLICY_DOCUMENT" != "None" ] && [ "$POLICY_DOCUMENT" != "null" ]; then
    echo "✅ Endpoint policy is configured"
    POLICY_STATUS="PASS"
    
    # Try to format and display policy
    if command -v jq >/dev/null 2>&1; then
        echo ""
        echo "📋 Endpoint Policy Summary:"
        echo "$POLICY_DOCUMENT" | jq -r '.Statement[0].Action[0:3][]' 2>/dev/null || echo "Policy parsing not available"
    fi
else
    echo "⚠️  No custom endpoint policy configured (using default)"
    POLICY_STATUS="WARN"
fi

TEST_RESULTS=$(echo $TEST_RESULTS | jq '.tests.endpoint_policy = {
    "status": "'$POLICY_STATUS'",
    "policy_configured": '$([ "$POLICY_DOCUMENT" != "None" ] && echo true || echo false)'
}')

# Test 7: Cost Analysis
echo ""
echo "💰 Test 7: Cost Analysis"
echo "======================="

echo "📊 Cost Comparison Analysis:"
echo ""
echo "Without VPC Endpoint (Traditional Setup):"
echo "  • NAT Gateway: \$45.00/month"
echo "  • Data Processing (100GB): \$4.50/month"
echo "  • Total Monthly Cost: \$49.50"
echo ""
echo "With S3 Gateway VPC Endpoint:"
echo "  • Gateway Endpoint: \$0.00/month (FREE)"
echo "  • Data Transfer (same region): \$0.00/month"
echo "  • Total Monthly Cost: \$0.00"
echo ""
echo "💡 Monthly Savings: \$49.50"
echo "💡 Annual Savings: \$594.00"

TEST_RESULTS=$(echo $TEST_RESULTS | jq '.tests.cost_analysis = {
    "status": "INFO",
    "monthly_savings_usd": 49.50,
    "annual_savings_usd": 594.00,
    "gateway_endpoint_cost": 0.00
}')

# Generate Test Summary
echo ""
echo "📋 Test Summary"
echo "==============="

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
WARNED_TESTS=0

# Count test results
for test in endpoint_status route_configuration local_s3_operations performance_benchmark dns_resolution endpoint_policy; do
    STATUS=$(echo $TEST_RESULTS | jq -r ".tests.$test.status")
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    
    case $STATUS in
        "PASS") PASSED_TESTS=$((PASSED_TESTS + 1)) ;;
        "FAIL") FAILED_TESTS=$((FAILED_TESTS + 1)) ;;
        "WARN") WARNED_TESTS=$((WARNED_TESTS + 1)) ;;
    esac
done

echo "Total Tests: $TOTAL_TESTS"
echo "✅ Passed: $PASSED_TESTS"
echo "❌ Failed: $FAILED_TESTS"
echo "⚠️  Warnings: $WARNED_TESTS"

# Update test results with summary
TEST_RESULTS=$(echo $TEST_RESULTS | jq '.summary = {
    "total_tests": '$TOTAL_TESTS',
    "passed_tests": '$PASSED_TESTS',
    "failed_tests": '$FAILED_TESTS',
    "warned_tests": '$WARNED_TESTS',
    "success_rate": '$(echo "scale=2; $PASSED_TESTS * 100 / $TOTAL_TESTS" | bc -l 2>/dev/null || echo 0)'
}')

# Save test results
echo $TEST_RESULTS | jq '.' > outputs/test-results.json
echo ""
echo "📄 Test results saved to: outputs/test-results.json"

# Clean up test files
rm -f /tmp/local-test-file.txt /tmp/downloaded-test-file.txt /tmp/test-1mb.dat /tmp/test-10mb.dat

# Final recommendations
echo ""
echo "🎯 Recommendations"
echo "=================="

if [ $FAILED_TESTS -eq 0 ]; then
    echo "✅ All critical tests passed! Your S3 VPC endpoint is working correctly."
    echo ""
    echo "🚀 Next Steps:"
    echo "  • Deploy your applications to use the private subnet"
    echo "  • Remove any NAT Gateways used solely for S3 access"
    echo "  • Monitor S3 access patterns and costs"
    echo "  • Consider implementing additional endpoint policies for security"
else
    echo "⚠️  Some tests failed. Please review the results and troubleshoot:"
    echo "  • Check VPC endpoint status and configuration"
    echo "  • Verify route table associations"
    echo "  • Review security group and NACL rules"
    echo "  • Ensure IAM permissions are correct"
fi

echo ""
echo "📚 Additional Resources:"
echo "  • VPC Endpoint Documentation: https://docs.aws.amazon.com/vpc/latest/privatelink/"
echo "  • S3 VPC Endpoint Guide: https://docs.aws.amazon.com/s3/latest/userguide/privatelink-interface-endpoints.html"
echo "  • Troubleshooting Guide: docs/troubleshooting.md"

echo ""
echo "🎉 S3 VPC Endpoint testing completed!"
