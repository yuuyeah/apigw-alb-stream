#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { ApigwAlbStreamStack } from '../lib/apigw-alb-stream-stack';

const app = new cdk.App();
new ApigwAlbStreamStack(app, 'ApigwAlbStreamStack', {

});