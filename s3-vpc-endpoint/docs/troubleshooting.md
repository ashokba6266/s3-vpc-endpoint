# S3 VPC Endpoint Troubleshooting Guide

## Common Issues and Solutions

### Issue 1: S3 Requests Still Going Through Internet

#### Symptoms
- High NAT Gateway data processing charges continue
- S3 access works but doesn't use VPC endpoint
- VPC Flow Logs show S3 traffic through NAT Gateway

#### Root Causes
1. Route table not associated with VPC endpoint
2. DNS resolution issues
3. Endpoint not in "Available" state
4. Application using specific S3 endpoint URLs

#### Diagnostic Steps
```bash
# Check endpoint status
aws ec2 describe-vpc-endpoints \
  --vpc-endpoint-ids vpce-xxxxxxxx \
  --query 'VpcEndpoints[0].State'

# Verify route table associations
aws ec2 describe-vpc-endpoints \
  --vpc-endpoint-ids vpce-xxxxxxxx \
  --query 'VpcEndpoints[0].RouteTableIds'

# Check route table entries
aws ec2 describe-route-tables \
  --route-table-ids rtb-xxxxxxxx \
  --query 'RouteTables[0].Routes[?GatewayId==`vpce-xxxxxxxx`]'
```

#### Solutions
1. **Verify Endpoint State**
   ```bash
   # Wait for endpoint to become available
   aws ec2 wait vpc-endpoint-available --vpc-endpoint-ids vpce-xxxxxxxx
   ```

2. **Check Route Table Association**
   ```bash
   # Associate route table with endpoint
   aws ec2 modify-vpc-endpoint \
     --vpc-endpoint-id vpce-xxxxxxxx \
     --add-route-table-ids rtb-xxxxxxxx
   ```

3. **Enable DNS Resolution**
   ```bash
   # Ensure VPC has DNS resolution enabled
   aws ec2 modify-vpc-attribute \
     --vpc-id vpc-xxxxxxxx \
     --enable-dns-support
   
   aws ec2 modify-vpc-attribute \
     --vpc-id vpc-xxxxxxxx \
     --enable-dns-hostnames
   ```

### Issue 2: Access Denied Errors

#### Symptoms
- HTTP 403 Forbidden errors
- "Access Denied" messages in application logs
- S3 operations fail with permission errors

#### Root Causes
1. Restrictive endpoint policy
2. S3 bucket policy blocking VPC access
3. IAM permissions insufficient
4. Condition keys in policies not met

#### Diagnostic Steps
```bash
# Check endpoint policy
aws ec2 describe-vpc-endpoints \
  --vpc-endpoint-ids vpce-xxxxxxxx \
  --query 'VpcEndpoints[0].PolicyDocument'

# Test S3 access with verbose output
aws s3 ls s3://bucket-name --debug

# Check IAM permissions
aws iam simulate-principal-policy \
  --policy-source-arn arn:aws:iam::123456789012:role/MyRole \
  --action-names s3:ListBucket \
  --resource-arns arn:aws:s3:::bucket-name
```

#### Solutions
1. **Review Endpoint Policy**
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Principal": "*",
         "Action": "s3:*",
         "Resource": "*"
       }
     ]
   }
   ```

2. **Update S3 Bucket Policy**
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Principal": "*",
         "Action": "s3:*",
         "Resource": [
           "arn:aws:s3:::bucket-name",
           "arn:aws:s3:::bucket-name/*"
         ],
         "Condition": {
           "StringEquals": {
             "aws:sourceVpc": "vpc-xxxxxxxx"
           }
         }
       }
     ]
   }
   ```

3. **Verify IAM Permissions**
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": [
           "s3:GetObject",
           "s3:PutObject",
           "s3:ListBucket"
         ],
         "Resource": [
           "arn:aws:s3:::bucket-name",
           "arn:aws:s3:::bucket-name/*"
         ]
       }
     ]
   }
   ```

### Issue 3: DNS Resolution Problems

#### Symptoms
- S3 DNS names don't resolve correctly
- Applications can't connect to S3
- Intermittent connectivity issues

#### Root Causes
1. VPC DNS settings disabled
2. Custom DNS servers configured
3. DNS caching issues
4. Network ACLs blocking DNS traffic

#### Diagnostic Steps
```bash
# Test DNS resolution
nslookup s3.us-east-1.amazonaws.com
dig s3.us-east-1.amazonaws.com

# Check VPC DNS settings
aws ec2 describe-vpcs \
  --vpc-ids vpc-xxxxxxxx \
  --query 'Vpcs[0].[EnableDnsSupport,EnableDnsHostnames]'

# Test from EC2 instance
curl -I https://s3.us-east-1.amazonaws.com
```

#### Solutions
1. **Enable VPC DNS Support**
   ```bash
   aws ec2 modify-vpc-attribute \
     --vpc-id vpc-xxxxxxxx \
     --enable-dns-support
   
   aws ec2 modify-vpc-attribute \
     --vpc-id vpc-xxxxxxxx \
     --enable-dns-hostnames
   ```

2. **Check DHCP Options Set**
   ```bash
   # Verify DHCP options
   aws ec2 describe-dhcp-options \
     --dhcp-options-ids dopt-xxxxxxxx
   ```

3. **Clear DNS Cache**
   ```bash
   # On EC2 instance
   sudo systemctl restart systemd-resolved
   # or
   sudo service nscd restart
   ```

### Issue 4: Performance Issues

#### Symptoms
- Slow S3 operations
- Timeouts on large file transfers
- High latency to S3

#### Root Causes
1. Network congestion
2. Incorrect region configuration
3. Suboptimal S3 request patterns
4. Security group restrictions

#### Diagnostic Steps
```bash
# Test network performance
curl -w "@curl-format.txt" -o /dev/null -s https://s3.us-east-1.amazonaws.com

# Check S3 transfer acceleration
aws s3api get-bucket-accelerate-configuration \
  --bucket bucket-name

# Monitor VPC Flow Logs
aws logs filter-log-events \
  --log-group-name VPCFlowLogs \
  --filter-pattern "{ $.action = \"REJECT\" }"
```

#### Solutions
1. **Optimize S3 Requests**
   ```bash
   # Use multipart uploads for large files
   aws configure set default.s3.multipart_threshold 64MB
   aws configure set default.s3.multipart_chunksize 16MB
   aws configure set default.s3.max_concurrent_requests 10
   ```

2. **Check Security Groups**
   ```bash
   # Ensure HTTPS (443) is allowed
   aws ec2 describe-security-groups \
     --group-ids sg-xxxxxxxx \
     --query 'SecurityGroups[0].IpPermissions'
   ```

3. **Use Correct Region**
   ```bash
   # Ensure S3 bucket and VPC endpoint are in same region
   aws s3api get-bucket-location --bucket bucket-name
   ```

### Issue 5: Endpoint Creation Failures

#### Symptoms
- VPC endpoint creation fails
- "InvalidParameter" errors
- Resource limit exceeded errors

#### Root Causes
1. Invalid route table IDs
2. VPC endpoint limits reached
3. Insufficient permissions
4. Service not available in region

#### Diagnostic Steps
```bash
# Check VPC endpoint limits
aws service-quotas get-service-quota \
  --service-code vpc \
  --quota-code L-45FE3B85

# Verify route table exists
aws ec2 describe-route-tables \
  --route-table-ids rtb-xxxxxxxx

# Check service availability
aws ec2 describe-vpc-endpoint-services \
  --service-names com.amazonaws.us-east-1.s3
```

#### Solutions
1. **Request Limit Increase**
   ```bash
   aws service-quotas request-service-quota-increase \
     --service-code vpc \
     --quota-code L-45FE3B85 \
     --desired-value 50
   ```

2. **Verify Permissions**
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": [
           "ec2:CreateVpcEndpoint",
           "ec2:DescribeVpcEndpoints",
           "ec2:ModifyVpcEndpoint"
         ],
         "Resource": "*"
       }
     ]
   }
   ```

## Monitoring and Alerting

### CloudWatch Metrics
```bash
# Monitor endpoint usage
aws cloudwatch get-metric-statistics \
  --namespace AWS/VPC \
  --metric-name PacketsDropped \
  --dimensions Name=VpcEndpointId,Value=vpce-xxxxxxxx \
  --start-time 2024-01-01T00:00:00Z \
  --end-time 2024-01-02T00:00:00Z \
  --period 3600 \
  --statistics Sum
```

### VPC Flow Logs Analysis
```bash
# Create VPC Flow Logs
aws ec2 create-flow-logs \
  --resource-type VPC \
  --resource-ids vpc-xxxxxxxx \
  --traffic-type ALL \
  --log-destination-type cloud-watch-logs \
  --log-group-name VPCFlowLogs

# Query for S3 traffic
aws logs filter-log-events \
  --log-group-name VPCFlowLogs \
  --filter-pattern "{ $.dstPort = 443 && $.protocol = 6 }"
```

### Health Checks
```bash
#!/bin/bash
# S3 VPC Endpoint Health Check Script

ENDPOINT_ID="vpce-xxxxxxxx"
BUCKET_NAME="test-bucket"
REGION="us-east-1"

# Check endpoint status
ENDPOINT_STATE=$(aws ec2 describe-vpc-endpoints \
  --vpc-endpoint-ids $ENDPOINT_ID \
  --region $REGION \
  --query 'VpcEndpoints[0].State' \
  --output text)

if [ "$ENDPOINT_STATE" != "available" ]; then
  echo "ERROR: VPC Endpoint not available - State: $ENDPOINT_STATE"
  exit 1
fi

# Test S3 connectivity
if aws s3 ls s3://$BUCKET_NAME --region $REGION > /dev/null 2>&1; then
  echo "SUCCESS: S3 connectivity through VPC endpoint working"
else
  echo "ERROR: S3 connectivity failed"
  exit 1
fi

echo "Health check passed"
```

## Best Practices for Prevention

### 1. Infrastructure as Code
```yaml
# CloudFormation template snippet
VPCEndpoint:
  Type: AWS::EC2::VPCEndpoint
  Properties:
    VpcId: !Ref VPC
    ServiceName: !Sub 'com.amazonaws.${AWS::Region}.s3'
    VpcEndpointType: Gateway
    RouteTableIds:
      - !Ref PrivateRouteTable
    PolicyDocument:
      Version: '2012-10-17'
      Statement:
        - Effect: Allow
          Principal: '*'
          Action: 's3:*'
          Resource: '*'
```

### 2. Automated Testing
```bash
#!/bin/bash
# Automated S3 VPC Endpoint Test

# Test endpoint creation
aws ec2 create-vpc-endpoint \
  --vpc-id vpc-xxxxxxxx \
  --service-name com.amazonaws.us-east-1.s3 \
  --vpc-endpoint-type Gateway \
  --route-table-ids rtb-xxxxxxxx

# Wait for availability
aws ec2 wait vpc-endpoint-available --vpc-endpoint-ids vpce-xxxxxxxx

# Test S3 operations
aws s3 ls
aws s3 cp test-file.txt s3://test-bucket/
aws s3 rm s3://test-bucket/test-file.txt
```

### 3. Monitoring Setup
```bash
# Create CloudWatch alarm for endpoint failures
aws cloudwatch put-metric-alarm \
  --alarm-name "S3-VPC-Endpoint-Failures" \
  --alarm-description "Alert on S3 VPC endpoint failures" \
  --metric-name PacketsDropped \
  --namespace AWS/VPC \
  --statistic Sum \
  --period 300 \
  --threshold 10 \
  --comparison-operator GreaterThanThreshold \
  --dimensions Name=VpcEndpointId,Value=vpce-xxxxxxxx
```

## Emergency Procedures

### Rollback Plan
1. **Remove VPC Endpoint**
   ```bash
   aws ec2 delete-vpc-endpoint --vpc-endpoint-id vpce-xxxxxxxx
   ```

2. **Restore NAT Gateway Route**
   ```bash
   aws ec2 create-route \
     --route-table-id rtb-xxxxxxxx \
     --destination-cidr-block 0.0.0.0/0 \
     --nat-gateway-id nat-xxxxxxxx
   ```

3. **Verify Connectivity**
   ```bash
   aws s3 ls --region us-east-1
   ```

### Contact Information
- **AWS Support**: Create support case for VPC endpoint issues
- **Documentation**: https://docs.aws.amazon.com/vpc/latest/privatelink/
- **Community**: AWS re:Post for community support

## Conclusion

Most S3 VPC endpoint issues are related to configuration rather than service problems. Following this troubleshooting guide and implementing the monitoring practices will help maintain reliable S3 connectivity through VPC endpoints.
