#!/bin/bash

# AWS Firewall Manager 前置条件检查和配置脚本
# 检查并配置 AWS Config、Organizations、RAM 等必需前置条件

set -e

# 配置变量 - 请根据实际环境修改
REGION="ap-northeast-1"               # 替换为你的区域

echo "=== AWS Firewall Manager 前置条件检查开始 ==="

# 1. 检查 AWS Organizations 配置
echo "1. 检查 AWS Organizations 配置..."
ORG_INFO=$(aws organizations describe-organization --region $REGION 2>/dev/null || echo "")

if [ -z "$ORG_INFO" ]; then
    echo "❌ AWS Organizations 未启用，请先启用 Organizations"
    exit 1
fi

FEATURE_SET=$(echo "$ORG_INFO" | jq -r '.Organization.FeatureSet')
if [ "$FEATURE_SET" != "ALL" ]; then
    echo "❌ Organizations 功能集为 '$FEATURE_SET'，需要启用 'ALL' 功能集"
    echo "请在 Organizations 控制台中启用所有功能"
    exit 1
fi

echo "✅ Organizations 配置正确 (功能集: $FEATURE_SET)"

# 2. 检查和启用 AWS Config
echo "2. 检查 AWS Config 配置..."

# 检查 Config Recorder 状态
CONFIG_RECORDERS=$(aws configservice describe-configuration-recorders --region $REGION --query 'ConfigurationRecorders' --output json 2>/dev/null || echo "[]")

if [ "$CONFIG_RECORDERS" = "[]" ] || [ -z "$CONFIG_RECORDERS" ]; then
    echo "⚠️  AWS Config 未配置，开始配置 Config..."
    
    # 获取账户ID
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    
    # 创建 Config 服务链接角色
    echo "创建 Config 服务链接角色..."
    aws iam create-service-linked-role --aws-service-name config.amazonaws.com --region $REGION 2>/dev/null || echo "服务角色可能已存在"
    
    # 创建 S3 bucket 用于 Config
    CONFIG_BUCKET="aws-config-bucket-${ACCOUNT_ID}-${REGION}"
    echo "创建 Config S3 bucket: $CONFIG_BUCKET"
    
    aws s3api create-bucket \
        --bucket "$CONFIG_BUCKET" \
        --create-bucket-configuration LocationConstraint=$REGION \
        --region $REGION 2>/dev/null || echo "Bucket 可能已存在"
    
    # 创建 bucket 策略
    cat > /tmp/config-bucket-policy.json << EOF
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
      "Resource": "arn:aws:s3:::${CONFIG_BUCKET}",
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
      "Resource": "arn:aws:s3:::${CONFIG_BUCKET}",
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
      "Resource": "arn:aws:s3:::${CONFIG_BUCKET}/*",
      "Condition": {
        "StringEquals": {
          "s3:x-amz-acl": "bucket-owner-full-control",
          "AWS:SourceAccount": "${ACCOUNT_ID}"
        }
      }
    }
  ]
}
EOF
    
    aws s3api put-bucket-policy --bucket "$CONFIG_BUCKET" --policy file:///tmp/config-bucket-policy.json --region $REGION
    
    # 创建 Configuration Recorder
    echo "创建 Configuration Recorder..."
    aws configservice put-configuration-recorder \
        --configuration-recorder name=default,roleARN=arn:aws:iam::${ACCOUNT_ID}:role/aws-service-role/config.amazonaws.com/AWSServiceRoleForConfig,recordingGroup='{resourceTypes=[AWS::EC2::VPC,AWS::NetworkFirewall::RuleGroup,AWS::NetworkFirewall::FirewallPolicy,AWS::EC2::InternetGateway,AWS::EC2::RouteTable,AWS::EC2::Subnet]}' \
        --region $REGION
    
    # 创建 Delivery Channel
    echo "创建 Delivery Channel..."
    aws configservice put-delivery-channel \
        --delivery-channel name=default,s3BucketName=$CONFIG_BUCKET \
        --region $REGION
    
    # 启动 Configuration Recorder
    echo "启动 Configuration Recorder..."
    aws configservice start-configuration-recorder \
        --configuration-recorder-name default \
        --region $REGION
    
    echo "✅ AWS Config 配置完成"
    
    # 等待 Config 启动
    echo "等待 Config 启动..."
    sleep 10
else
    echo "检查现有 Config Recorder 状态..."
    CONFIG_STATUS=$(aws configservice describe-configuration-recorder-status --region $REGION --query 'ConfigurationRecordersStatus[0]' --output json)
    
    RECORDING=$(echo "$CONFIG_STATUS" | jq -r '.recording')
    LAST_STATUS=$(echo "$CONFIG_STATUS" | jq -r '.lastStatus')
    
    if [ "$RECORDING" = "true" ] && [ "$LAST_STATUS" = "SUCCESS" ]; then
        echo "✅ AWS Config 已正确配置并运行"
    elif [ "$RECORDING" = "false" ]; then
        echo "⚠️  Config Recorder 未运行，启动中..."
        aws configservice start-configuration-recorder --configuration-recorder-name default --region $REGION
        sleep 10
        echo "✅ Config Recorder 已启动"
    else
        echo "⚠️  Config 状态: $LAST_STATUS，继续执行..."
    fi
fi

# 3. 检查和启用 AWS RAM 资源共享
echo "3. 检查 AWS RAM 资源共享..."
RAM_STATUS=$(aws ram get-resource-share-associations --association-type RESOURCE --region $REGION 2>/dev/null || echo "")

echo "启用 AWS RAM 组织级资源共享..."
aws ram enable-sharing-with-aws-organization --region $REGION 2>/dev/null || echo "资源共享可能已启用"
echo "✅ AWS RAM 资源共享已启用"

# 4. 检查 Firewall Manager 管理员账户
echo "4. 检查 Firewall Manager 管理员账户..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

CURRENT_ADMIN=$(aws fms get-admin-account --region $REGION --query 'AdminAccount' --output text 2>/dev/null || echo "None")

if [ "$CURRENT_ADMIN" = "$ACCOUNT_ID" ]; then
    echo "✅ 当前账户已经是 Firewall Manager 管理员账户"
elif [ "$CURRENT_ADMIN" != "None" ] && [ "$CURRENT_ADMIN" != "null" ]; then
    echo "⚠️  检测到其他账户 ($CURRENT_ADMIN) 已设置为管理员"
    echo "如需更改，请先撤销现有管理员账户"
else
    echo "设置 Firewall Manager 管理员账户..."
    aws fms put-admin-account --admin-account $ACCOUNT_ID --region $REGION
    echo "✅ Firewall Manager 管理员账户设置完成"
    
    # 等待管理员账户设置完成
    echo "等待管理员账户设置完成..."
    sleep 30
fi

# 5. 最终验证
echo "5. 最终验证所有前置条件..."

# 验证 Config 状态
CONFIG_FINAL_STATUS=$(aws configservice describe-configuration-recorder-status --region $REGION --query 'ConfigurationRecordersStatus[0].recording' --output text 2>/dev/null || echo "false")

# 验证 Firewall Manager 管理员
FMS_ADMIN_STATUS=$(aws fms get-admin-account --region $REGION --query 'RoleStatus' --output text 2>/dev/null || echo "NOT_READY")

echo ""
echo "=== 前置条件检查结果 ==="
echo "✅ AWS Organizations: 已启用 (功能集: ALL)"
echo "$([ "$CONFIG_FINAL_STATUS" = "true" ] && echo "✅" || echo "⚠️ ") AWS Config: $([ "$CONFIG_FINAL_STATUS" = "true" ] && echo "运行中" || echo "配置中")"
echo "✅ AWS RAM: 资源共享已启用"
echo "$([ "$FMS_ADMIN_STATUS" = "READY" ] && echo "✅" || echo "⚠️ ") Firewall Manager: $([ "$FMS_ADMIN_STATUS" = "READY" ] && echo "管理员账户就绪" || echo "管理员账户配置中")"

if [ "$CONFIG_FINAL_STATUS" = "true" ] && [ "$FMS_ADMIN_STATUS" = "READY" ]; then
    echo ""
    echo "🎉 所有前置条件已满足，可以继续执行 ./deploy-1-firewall-manager.sh"
else
    echo ""
    echo "⚠️  部分前置条件仍在配置中，请等待几分钟后再执行后续脚本"
    echo "可以运行以下命令检查状态："
    echo "  aws configservice describe-configuration-recorder-status --region $REGION"
    echo "  aws fms get-admin-account --region $REGION"
fi

echo ""
echo "前置条件配置脚本执行完成！"
