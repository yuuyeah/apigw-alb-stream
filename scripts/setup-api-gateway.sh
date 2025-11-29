#!/bin/bash

set -e

# Configuration
STACK_NAME="${STACK_NAME:-ApigwAlbStreamStack}"
VPC_LINK_NAME="test-vpc-link-v2"
API_NAME="test-rest-api"
STAGE_NAME="test"

echo "=========================================="
echo "API Gateway Setup Script"
echo "=========================================="
echo ""

# Get CloudFormation outputs
echo "📋 Fetching CloudFormation outputs from stack: $STACK_NAME"
OUTPUTS=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --query 'Stacks[0].Outputs' --output json)

ALB_DNS=$(echo "$OUTPUTS" | jq -r '.[] | select(.OutputKey=="ALBDnsName") | .OutputValue')
ALB_ARN=$(echo "$OUTPUTS" | jq -r '.[] | select(.OutputKey=="ALBArn") | .OutputValue')
SG_ID=$(echo "$OUTPUTS" | jq -r '.[] | select(.OutputKey=="VpcLinkSecurityGroupId") | .OutputValue')
SUBNET_IDS=$(echo "$OUTPUTS" | jq -r '.[] | select(.OutputKey=="PrivateSubnetIds") | .OutputValue')

echo "  ALB DNS: $ALB_DNS"
echo "  ALB ARN: $ALB_ARN"
echo "  Security Group: $SG_ID"
echo "  Subnet IDs: $SUBNET_IDS"
echo ""

# Convert comma-separated subnet IDs to array
IFS=',' read -ra SUBNET_ARRAY <<< "$SUBNET_IDS"

# Create VPC Link v2
echo "🔗 Creating VPC Link v2: $VPC_LINK_NAME"
VPC_LINK_OUTPUT=$(aws apigatewayv2 create-vpc-link \
  --name "$VPC_LINK_NAME" \
  --subnet-ids "${SUBNET_ARRAY[@]}" \
  --security-group-ids "$SG_ID" \
  --output json)

VPC_LINK_ID=$(echo "$VPC_LINK_OUTPUT" | jq -r '.VpcLinkId')
echo "  VPC Link ID: $VPC_LINK_ID"
echo ""

# Wait for VPC Link to be available
echo "⏳ Waiting for VPC Link to become available (checking every 30 seconds)..."
while true; do
  VPC_LINK_STATUS=$(aws apigatewayv2 get-vpc-link --vpc-link-id "$VPC_LINK_ID" --query 'VpcLinkStatus' --output text)
  echo "  Current status: $VPC_LINK_STATUS"
  
  if [ "$VPC_LINK_STATUS" == "AVAILABLE" ]; then
    echo "✅ VPC Link is now available!"
    break
  elif [ "$VPC_LINK_STATUS" == "FAILED" ]; then
    echo "❌ VPC Link creation failed!"
    exit 1
  fi
  
  sleep 30
done
echo ""

# Create REST API
echo "🌐 Creating REST API: $API_NAME"
API_OUTPUT=$(aws apigateway create-rest-api \
  --name "$API_NAME" \
  --description "REST API integration with internal ALB via VPC link v2" \
  --output json)

REST_API_ID=$(echo "$API_OUTPUT" | jq -r '.id')
echo "  REST API ID: $REST_API_ID"
echo ""

# Get root resource ID
echo "📂 Getting root resource ID"
ROOT_RESOURCE_ID=$(aws apigateway get-resources \
  --rest-api-id "$REST_API_ID" \
  --query 'items[0].id' \
  --output text)
echo "  Root Resource ID: $ROOT_RESOURCE_ID"
echo ""

# Create {proxy+} resource
echo "📁 Creating {proxy+} resource"
PROXY_RESOURCE_OUTPUT=$(aws apigateway create-resource \
  --rest-api-id "$REST_API_ID" \
  --parent-id "$ROOT_RESOURCE_ID" \
  --path-part "{proxy+}" \
  --output json)

PROXY_RESOURCE_ID=$(echo "$PROXY_RESOURCE_OUTPUT" | jq -r '.id')
echo "  Proxy Resource ID: $PROXY_RESOURCE_ID"
echo ""

# Put method on {proxy+} resource
echo "🔧 Setting up ANY method on {proxy+} resource"
aws apigateway put-method \
  --rest-api-id "$REST_API_ID" \
  --resource-id "$PROXY_RESOURCE_ID" \
  --http-method ANY \
  --authorization-type NONE \
  --request-parameters "method.request.path.proxy=true" \
  --output json > /dev/null
echo "  ✅ Method created"
echo ""

# Put integration on {proxy+} resource
echo "🔌 Setting up HTTP_PROXY integration on {proxy+} resource (with STREAM mode)"
aws apigateway put-integration \
  --rest-api-id "$REST_API_ID" \
  --resource-id "$PROXY_RESOURCE_ID" \
  --http-method ANY \
  --type HTTP_PROXY \
  --integration-http-method ANY \
  --uri "http://${ALB_DNS}/{proxy}" \
  --connection-type VPC_LINK \
  --connection-id "$VPC_LINK_ID" \
  --request-parameters "integration.request.path.proxy=method.request.path.proxy" \
  --response-transfer-mode STREAM \
  --timeout-in-millis 60000 \
  --output json > /dev/null
echo "  ✅ Integration created"
echo ""

# Put method on root resource
echo "🔧 Setting up ANY method on root resource"
aws apigateway put-method \
  --rest-api-id "$REST_API_ID" \
  --resource-id "$ROOT_RESOURCE_ID" \
  --http-method ANY \
  --authorization-type NONE \
  --output json > /dev/null
echo "  ✅ Method created"
echo ""

# Put integration on root resource
echo "🔌 Setting up HTTP_PROXY integration on root resource (with STREAM mode)"
aws apigateway put-integration \
  --rest-api-id "$REST_API_ID" \
  --resource-id "$ROOT_RESOURCE_ID" \
  --http-method ANY \
  --type HTTP_PROXY \
  --integration-http-method ANY \
  --uri "http://${ALB_DNS}/" \
  --connection-type VPC_LINK \
  --connection-id "$VPC_LINK_ID" \
  --response-transfer-mode STREAM \
  --timeout-in-millis 60000 \
  --output json > /dev/null
echo "  ✅ Integration created"
echo ""

# Create deployment
echo "🚀 Creating deployment to stage: $STAGE_NAME"
aws apigateway create-deployment \
  --rest-api-id "$REST_API_ID" \
  --stage-name "$STAGE_NAME" \
  --output json > /dev/null
echo "  ✅ Deployment created"
echo ""

# Get API endpoint
API_ENDPOINT="https://${REST_API_ID}.execute-api.${AWS_REGION:-us-east-1}.amazonaws.com/${STAGE_NAME}"

echo "=========================================="
echo "✅ Setup Complete!"
echo "=========================================="
echo ""
echo "📝 Summary:"
echo "  VPC Link ID: $VPC_LINK_ID"
echo "  REST API ID: $REST_API_ID"
echo "  API Endpoint: $API_ENDPOINT"
echo ""
echo "🧪 Test your API:"
echo "  curl $API_ENDPOINT/health"
echo "  curl $API_ENDPOINT/stream"
echo ""
