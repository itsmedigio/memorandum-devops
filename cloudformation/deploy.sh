#!/bin/zsh

KEYPAIR_NAME="key-050481db8cc2e913b"
SUBNET_ID="subnet-02d0c0efa2b908923"

aws cloudformation deploy \
  --stack-name my-ec2-stack \
  --template-file ./ec2_instance.json \
  --parameter-overrides \
      KeyName="$KEYPAIR_NAME" \
      Subnets="$SUBNET_ID" \
      InstanceType="t3.micro" \
      SSHLocation="0.0.0.0/0"