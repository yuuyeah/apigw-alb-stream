import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import { Construct } from 'constructs';
import { EcsAppConstruct } from './constructs/ecs-app-construct';

export class ApigwAlbStreamStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    // VPC (Private Subnetのみ、NAT Gatewayなし)
    const vpc = new ec2.Vpc(this, 'Vpc', {
      maxAzs: 2,
      natGateways: 0,
      subnetConfiguration: [
        {
          cidrMask: 24,
          name: 'Private',
          subnetType: ec2.SubnetType.PRIVATE_ISOLATED,
        },
      ],
    });

    // VPC Endpoints
    vpc.addInterfaceEndpoint('EcrDockerEndpoint', {
      service: ec2.InterfaceVpcEndpointAwsService.ECR_DOCKER,
    });
    vpc.addInterfaceEndpoint('EcrEndpoint', {
      service: ec2.InterfaceVpcEndpointAwsService.ECR,
    });
    vpc.addGatewayEndpoint('S3Endpoint', {
      service: ec2.GatewayVpcEndpointAwsService.S3,
    });
    vpc.addInterfaceEndpoint('CloudWatchLogsEndpoint', {
      service: ec2.InterfaceVpcEndpointAwsService.CLOUDWATCH_LOGS,
    });
    vpc.addInterfaceEndpoint('BedrockRuntimeEndpoint', {
      service: ec2.InterfaceVpcEndpointAwsService.BEDROCK_RUNTIME,
    });

    // ECS App
    const ecsApp = new EcsAppConstruct(this, 'EcsApp', {
      vpc,
      appPath: './app',
    });

    // VPC Link Security Group
    const vpcLinkSecurityGroup = new ec2.SecurityGroup(this, 'VpcLinkSecurityGroup', {
      vpc,
      description: 'Security Group for VPC Link',
      allowAllOutbound: false,
    });

    // Inbound: 443 from anywhere
    vpcLinkSecurityGroup.addIngressRule(
      ec2.Peer.anyIpv4(),
      ec2.Port.tcp(443),
      'Allow HTTPS from anywhere'
    );

    // Outbound: 80
    vpcLinkSecurityGroup.addEgressRule(
      ec2.Peer.anyIpv4(),
      ec2.Port.tcp(80),
      'Allow HTTP outbound'
    );

    // Outputs
    new cdk.CfnOutput(this, 'ALBDnsName', {
      value: ecsApp.alb.loadBalancerDnsName,
      description: 'Private ALB DNS Name',
    });

    new cdk.CfnOutput(this, 'VpcLinkSecurityGroupId', {
      value: vpcLinkSecurityGroup.securityGroupId,
      description: 'Security Group ID for VPC Link',
      exportName: 'VpcLinkSecurityGroupId',
    });

    new cdk.CfnOutput(this, 'PrivateSubnetIds', {
      value: vpc.privateSubnets.map(subnet => subnet.subnetId).join(','),
      description: 'Private Subnet IDs for VPC Link',
      exportName: 'PrivateSubnetIds',
    });

  }
}
