#!/bin/bash

# 为成员账户启用 AWS Config 的脚本
# 注意：这需要在每个成员账户中执行，或者使用 CloudFormation StackSets

set -e

REGION="ap-northeast-1"

echo "=== 为成员账户启用 AWS Config ==="

# 获取 SecurityOU 中的账户列表
echo "获取 SecurityOU 中的账户列表..."
MEMBER_ACCOUNTS=$(aws organizations list-accounts-for-parent \
  --parent-id ou-2949-qksovdg7 \
  --query 'Accounts[*].Id' \
  --output text)

echo "SecurityOU 中的成员账户: $MEMBER_ACCOUNTS"

echo ""
echo "⚠️  重要提示："
echo "由于跨账户权限限制，需要在每个成员账户中手动执行以下步骤："
echo ""

for ACCOUNT_ID in $MEMBER_ACCOUNTS; do
    echo "=== 账户 $ACCOUNT_ID 的配置步骤 ==="
    echo ""
    echo "1. 切换到账户 $ACCOUNT_ID 的管理员角色"
    echo "2. 执行以下命令："
    echo ""
    
    cat << EOF
# 创建 Config 服务链接角色
aws iam create-service-linked-role --aws-service-name config.amazonaws.com --region $REGION

# 创建 S3 bucket
CONFIG_BUCKET="aws-config-bucket-${ACCOUNT_ID}-${REGION}"
aws s3api create-bucket \\
    --bucket "\$CONFIG_BUCKET" \\
    --create-bucket-configuration LocationConstraint=$REGION \\
    --region $REGION

# 创建 bucket 策略
cat > /tmp/config-bucket-policy-${ACCOUNT_ID}.json << 'POLICY_EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AWSConfigBucketPermissionsCheck",
      "Effect": "Allow",
      "Principal": {
        "Service": "config.amazonaws.com"
      },
      "Action": "s3:GetBucketAcl",
      "Resource": "arn:aws:s3:::aws-config-bucket-${ACCOUNT_ID}-${REGION}",
      "Condition": {
        "StringEquals": {
          "AWS:SourceAccount": "${ACCOUNT_ID}"
        }
      }
    },
    {
      "Sid": "AWSConfigBucketExistenceCheck",
      "Effect": "Allow",
      "Principal": {
        "Service": "config.amazonaws.com"
      },
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::aws-config-bucket-${ACCOUNT_ID}-${REGION}",
      "Condition": {
        "StringEquals": {
          "AWS:SourceAccount": "${ACCOUNT_ID}"
        }
      }
    },
    {
      "Sid": "AWSConfigBucketDelivery",
      "Effect": "Allow",
      "Principal": {
        "Service": "config.amazonaws.com"
      },
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::aws-config-bucket-${ACCOUNT_ID}-${REGION}/*",
      "Condition": {
        "StringEquals": {
          "s3:x-amz-acl": "bucket-owner-full-control",
          "AWS:SourceAccount": "${ACCOUNT_ID}"
        }
      }
    }
  ]
}
POLICY_EOF

aws s3api put-bucket-policy --bucket "\$CONFIG_BUCKET" --policy file:///tmp/config-bucket-policy-${ACCOUNT_ID}.json --region $REGION

# 创建 Configuration Recorder
aws configservice put-configuration-recorder \\
    --configuration-recorder name=default,roleARN=arn:aws:iam::${ACCOUNT_ID}:role/aws-service-role/config.amazonaws.com/AWSServiceRoleForConfig,recordingGroup='{resourceTypes=[AWS::EC2::VPC,AWS::NetworkFirewall::RuleGroup,AWS::NetworkFirewall::FirewallPolicy,AWS::NetworkFirewall::Firewall,AWS::Route53Resolver::FirewallRuleGroupAssociation,AWS::Route53Resolver::FirewallRuleGroup,AWS::Route53Resolver::FirewallDomainList,AWS::EC2::InternetGateway,AWS::EC2::RouteTable,AWS::EC2::Subnet]}' \\
    --region $REGION

# 创建 Delivery Channel
aws configservice put-delivery-channel \\
    --delivery-channel name=default,s3BucketName=\$CONFIG_BUCKET \\
    --region $REGION

# 启动 Configuration Recorder
aws configservice start-configuration-recorder \\
    --configuration-recorder-name default \\
    --region $REGION

echo "账户 ${ACCOUNT_ID} 的 AWS Config 配置完成"

EOF
    echo ""
    echo "----------------------------------------"
    echo ""
done

echo "=== 使用 CloudFormation StackSets 的替代方案 ==="
echo ""
echo "如果你有 StackSets 权限，可以使用以下方法批量部署："
echo ""
echo "1. 创建 CloudFormation 模板用于启用 Config"
echo "2. 使用 StackSets 部署到 SecurityOU"
echo "3. 命令示例："
echo ""
cat << 'EOF'
aws cloudformation create-stack-set \
    --stack-set-name EnableConfigForFirewallManager \
    --template-body file://enable-config-template.yaml \
    --capabilities CAPABILITY_IAM \
    --operation-preferences RegionConcurrencyType=PARALLEL,MaxConcurrentPercentage=100

aws cloudformation create-stack-instances \
    --stack-set-name EnableConfigForFirewallManager \
    --deployment-targets OrganizationalUnitIds=ou-2949-qksovdg7 \
    --regions ap-northeast-1
EOF

echo ""
echo "配置完成后，等待 10-15 分钟，然后重新检查 Firewall Manager 合规状态。"
