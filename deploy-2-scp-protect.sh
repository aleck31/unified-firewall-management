#!/bin/bash

# AWS SCP 策略部署脚本
# 仅部署 SCP 保护策略，不包含 Firewall Manager

set -e

# 配置变量 - 请根据实际环境修改
REGION="ap-northeast-1"               # 替换为你的区域

echo "=== AWS SCP 保护策略部署开始 ==="

# 1. 环境准备和验证
echo "1. 验证 AWS Organizations 环境..."
aws organizations describe-organization --region $REGION || {
    echo "错误: AWS Organizations 未启用"
    exit 1
}

# 获取环境信息
ADMIN_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ROOT_OU_ID=$(aws organizations list-roots --query 'Roots[0].Id' --output text)

echo "管理员账户ID: $ADMIN_ACCOUNT_ID"
echo "根 OU ID: $ROOT_OU_ID"

# 2. 验证 SCP 策略文件存在
echo "2. 验证 SCP 策略文件..."
if [ ! -f "policies/scp-firewall-protection.json" ]; then
    echo "❌ 找不到 SCP 策略文件: policies/scp-firewall-protection.json"
    exit 1
fi

echo "✅ SCP 策略文件存在"

# 3. 检查现有 SCP 策略
echo "3. 检查现有 SCP 策略..."
EXISTING_POLICY=$(aws organizations list-policies \
  --filter SERVICE_CONTROL_POLICY \
  --query 'Policies[?Name==`FirewallProtectionPolicy`].Id' \
  --output text)

if [ ! -z "$EXISTING_POLICY" ] && [ "$EXISTING_POLICY" != "None" ]; then
    echo "⚠️  检测到现有的防火墙保护策略: $EXISTING_POLICY"
    echo "是否要更新现有策略？(y/N)"
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        echo "更新现有 SCP 策略..."
        aws organizations update-policy \
          --policy-id "$EXISTING_POLICY" \
          --content file://policies/scp-firewall-protection.json
        SCP_POLICY_ID="$EXISTING_POLICY"
        echo "✅ SCP 策略已更新"
    else
        echo "使用现有策略: $EXISTING_POLICY"
        SCP_POLICY_ID="$EXISTING_POLICY"
    fi
else
    # 4. 创建新的 SCP 策略
    echo "4. 创建 SCP 保护策略..."
    SCP_POLICY_ID=$(aws organizations create-policy \
      --name "FirewallProtectionPolicy" \
      --description "Prevent unauthorized firewall modifications while allowing Firewall Manager" \
      --type SERVICE_CONTROL_POLICY \
      --content file://policies/scp-firewall-protection.json \
      --query 'Policy.PolicySummary.Id' \
      --output text)

    echo "✅ SCP 策略已创建，策略 ID: $SCP_POLICY_ID"
fi

# 5. 检查策略是否已应用到根 OU
echo "5. 检查策略应用状态..."
ATTACHED_POLICIES=$(aws organizations list-policies-for-target \
  --target-id "$ROOT_OU_ID" \
  --filter SERVICE_CONTROL_POLICY \
  --query 'Policies[?Id==`'$SCP_POLICY_ID'`].Id' \
  --output text)

if [ ! -z "$ATTACHED_POLICIES" ] && [ "$ATTACHED_POLICIES" != "None" ]; then
    echo "✅ SCP 策略已应用到根 OU"
else
    # 6. 应用 SCP 策略到根 OU
    echo "6. 应用 SCP 策略到根 OU..."
    aws organizations attach-policy \
      --policy-id "$SCP_POLICY_ID" \
      --target-id "$ROOT_OU_ID"

    echo "✅ SCP 策略已应用到根 OU"
fi

# 7. 验证部署
echo "7. 验证 SCP 策略部署状态..."
sleep 10  # 等待策略生效

echo "=== SCP 策略应用状态 ==="
aws organizations list-policies-for-target \
  --target-id "$ROOT_OU_ID" \
  --filter SERVICE_CONTROL_POLICY \
  --query 'Policies[*].[Name,Id]' \
  --output table

echo "=== SCP 策略部署完成 ==="
echo "✅ SCP 保护策略已创建并应用"
echo "✅ 所有成员账户现在受到防火墙修改保护"
echo ""
echo "策略详情:"
echo "- 策略名称: FirewallProtectionPolicy"
echo "- 策略 ID: $SCP_POLICY_ID"
echo "- 应用范围: 根 OU (影响所有成员账户)"
echo ""
echo "监控地址:"
echo "- Organizations: https://console.aws.amazon.com/organizations"
echo ""
echo "下一步:"
echo "1. 在 AWS 控制台中验证策略状态"
echo "2. 测试成员账户是否被正确阻止修改防火墙"
echo "3. 监控 CloudTrail 中的拒绝事件"

echo "SCP 策略部署脚本执行完成！"
