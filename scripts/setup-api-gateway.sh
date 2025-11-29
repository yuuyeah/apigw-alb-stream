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

# Check if VPC Link already exists
echo "🔗 Checking for existing VPC Link: $VPC_LINK_NAME"
EXISTING_VPC_LINK=$(aws apigatewayv2 get-vpc-links --query "Items[?Name=='$VPC_LINK_NAME'] | [0]" --output json)
VPC_LINK_ID=$(echo "$EXISTING_VPC_LINK" | jq -r '.VpcLinkId // empty')

if [ -n "$VPC_LINK_ID" ] && [ "$VPC_LINK_ID" != "null" ]; then
  echo "  ✅ Found existing VPC Link: $VPC_LINK_ID"
  VPC_LINK_STATUS=$(echo "$EXISTING_VPC_LINK" | jq -r '.VpcLinkStatus')
  echo "  Current status: $VPC_LINK_STATUS"
else
  echo "  Creating new VPC Link..."
  VPC_LINK_OUTPUT=$(aws apigatewayv2 create-vpc-link \
    --name "$VPC_LINK_NAME" \
    --subnet-ids "${SUBNET_ARRAY[@]}" \
    --security-group-ids "$SG_ID" \
    --output json)
  
  VPC_LINK_ID=$(echo "$VPC_LINK_OUTPUT" | jq -r '.VpcLinkId')
  echo "  VPC Link ID: $VPC_LINK_ID"
  VPC_LINK_STATUS="PENDING"
fi
echo ""

# Wait for VPC Link to be available
if [ "$VPC_LINK_STATUS" != "AVAILABLE" ]; then
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
fi

# Check if REST API already exists
echo "🌐 Checking for existing REST API: $API_NAME"
EXISTING_API=$(aws apigateway get-rest-apis --query "items[?name=='$API_NAME'] | [0]" --output json)
REST_API_ID=$(echo "$EXISTING_API" | jq -r '.id // empty')

if [ -n "$REST_API_ID" ] && [ "$REST_API_ID" != "null" ]; then
  echo "  ✅ Found existing REST API: $REST_API_ID"
else
  echo "  Creating new REST API (Regional endpoint)..."
  API_OUTPUT=$(aws apigateway create-rest-api \
    --name "$API_NAME" \
    --description "REST API integration with internal ALB via VPC link v2" \
    --endpoint-configuration types=REGIONAL \
    --output json)
  
  REST_API_ID=$(echo "$API_OUTPUT" | jq -r '.id')
  echo "  REST API ID: $REST_API_ID"
fi
echo ""

# Get root resource ID
echo "📂 Getting root resource ID"
ROOT_RESOURCE_ID=$(aws apigateway get-resources \
  --rest-api-id "$REST_API_ID" \
  --query 'items[0].id' \
  --output text)
echo "  Root Resource ID: $ROOT_RESOURCE_ID"
echo ""

# Check if {proxy+} resource already exists
echo "📁 Checking for {proxy+} resource"
EXISTING_PROXY=$(aws apigateway get-resources --rest-api-id "$REST_API_ID" --query "items[?pathPart=='{proxy+}'] | [0]" --output json)
PROXY_RESOURCE_ID=$(echo "$EXISTING_PROXY" | jq -r '.id // empty')

if [ -n "$PROXY_RESOURCE_ID" ] && [ "$PROXY_RESOURCE_ID" != "null" ]; then
  echo "  ✅ Found existing {proxy+} resource: $PROXY_RESOURCE_ID"
else
  echo "  Creating {proxy+} resource..."
  PROXY_RESOURCE_OUTPUT=$(aws apigateway create-resource \
    --rest-api-id "$REST_API_ID" \
    --parent-id "$ROOT_RESOURCE_ID" \
    --path-part "{proxy+}" \
    --output json)
  
  PROXY_RESOURCE_ID=$(echo "$PROXY_RESOURCE_OUTPUT" | jq -r '.id')
  echo "  Proxy Resource ID: $PROXY_RESOURCE_ID"
fi
echo ""

# Put method on {proxy+} resource
echo "🔧 Setting up ANY method on {proxy+} resource"
if aws apigateway get-method --rest-api-id "$REST_API_ID" --resource-id "$PROXY_RESOURCE_ID" --http-method ANY &>/dev/null; then
  echo "  ✅ Method already exists, updating..."
  aws apigateway update-method \
    --rest-api-id "$REST_API_ID" \
    --resource-id "$PROXY_RESOURCE_ID" \
    --http-method ANY \
    --patch-operations op=replace,path=/authorizationType,value=NONE \
    --output json > /dev/null
else
  aws apigateway put-method \
    --rest-api-id "$REST_API_ID" \
    --resource-id "$PROXY_RESOURCE_ID" \
    --http-method ANY \
    --authorization-type NONE \
    --request-parameters "method.request.path.proxy=true" \
    --output json > /dev/null
  echo "  ✅ Method created"
fi
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
  --integration-target "$ALB_ARN" \
  --request-parameters '{"integration.request.path.proxy":"method.request.path.proxy"}' \
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
echo "  # Health check"
echo "  curl $API_ENDPOINT/health"
echo ""
echo "  # Streaming test"
echo "  curl -X POST $API_ENDPOINT/stream \\"
echo "    -H \"Content-Type: application/json\" \\"
echo "    -d '{\"message\": \"こんにちは\"}' \\"
echo "    --no-buffer"
echo ""
