#!/bin/bash
set -e

STACK_NAME="${STACK_NAME:-ApigwAlbStreamStack}"
VPC_LINK_NAME="test-vpc-link-v2"
API_NAME="test-rest-api"
STAGE_NAME="test"

echo "📋 CloudFormation outputs取得中..."
OUTPUTS=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --query 'Stacks[0].Outputs' --output json)
ALB_DNS=$(echo "$OUTPUTS" | jq -r '.[] | select(.OutputKey=="ALBDnsName") | .OutputValue')
ALB_ARN=$(echo "$OUTPUTS" | jq -r '.[] | select(.OutputKey=="ALBArn") | .OutputValue')
SG_ID=$(echo "$OUTPUTS" | jq -r '.[] | select(.OutputKey=="VpcLinkSecurityGroupId") | .OutputValue')
SUBNET_IDS=$(echo "$OUTPUTS" | jq -r '.[] | select(.OutputKey=="PrivateSubnetIds") | .OutputValue')
IFS=',' read -ra SUBNET_ARRAY <<< "$SUBNET_IDS"

echo "🔗 VPC Link作成中..."
VPC_LINK_OUTPUT=$(aws apigatewayv2 create-vpc-link \
  --name "$VPC_LINK_NAME" \
  --subnet-ids "${SUBNET_ARRAY[@]}" \
  --security-group-ids "$SG_ID" \
  --output json)
VPC_LINK_ID=$(echo "$VPC_LINK_OUTPUT" | jq -r '.VpcLinkId')

echo "⏳ VPC Link待機中 (2-3分かかります)..."
while true; do
  VPC_LINK_STATUS=$(aws apigatewayv2 get-vpc-link --vpc-link-id "$VPC_LINK_ID" --query 'VpcLinkStatus' --output text)
  echo "  Status: $VPC_LINK_STATUS"
  [ "$VPC_LINK_STATUS" == "AVAILABLE" ] && break
  [ "$VPC_LINK_STATUS" == "FAILED" ] && exit 1
  sleep 30
done

echo "🌐 REST API作成中..."
API_OUTPUT=$(aws apigateway create-rest-api \
  --name "$API_NAME" \
  --endpoint-configuration types=REGIONAL \
  --output json)
REST_API_ID=$(echo "$API_OUTPUT" | jq -r '.id')

echo "📁 リソース設定中..."
ROOT_RESOURCE_ID=$(aws apigateway get-resources --rest-api-id "$REST_API_ID" --query 'items[0].id' --output text)
PROXY_RESOURCE_OUTPUT=$(aws apigateway create-resource \
  --rest-api-id "$REST_API_ID" \
  --parent-id "$ROOT_RESOURCE_ID" \
  --path-part "{proxy+}" \
  --output json)
PROXY_RESOURCE_ID=$(echo "$PROXY_RESOURCE_OUTPUT" | jq -r '.id')

echo "🔧 メソッド・インテグレーション設定中..."
aws apigateway put-method \
  --rest-api-id "$REST_API_ID" \
  --resource-id "$PROXY_RESOURCE_ID" \
  --http-method ANY \
  --authorization-type NONE \
  --request-parameters "method.request.path.proxy=true" > /dev/null

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
  --timeout-in-millis 60000 > /dev/null

echo "🚀 デプロイ中..."
aws apigateway create-deployment \
  --rest-api-id "$REST_API_ID" \
  --stage-name "$STAGE_NAME" > /dev/null

API_ENDPOINT="https://${REST_API_ID}.execute-api.${AWS_REGION:-us-east-1}.amazonaws.com/${STAGE_NAME}"

echo ""
echo "✅ Setup Complete!"
echo "API Endpoint: $API_ENDPOINT"
echo ""
echo "🧪 Test commands:"
echo "  curl $API_ENDPOINT/health"
echo "  curl -X POST $API_ENDPOINT/stream -H 'Content-Type: application/json' -d '{\"message\":\"こんにちは\"}' --no-buffer"
