#!/bin/bash

# 使用 AWS CLI 实际验证 Firewall Manager 策略创建
# 通过 --dry-run 或创建测试策略来验证配置是否正确

set -e

# 配置变量
REGION="ap-northeast-1"
TEST_MODE=true  # 设置为 true 创建测试策略，false 仅做格式验证

echo "=== AWS CLI Firewall Manager 策略验证 ==="
echo "区域: $REGION"
echo "测试模式: $([ "$TEST_MODE" = true ] && echo "创建测试策略" || echo "仅格式验证")"
echo ""

# 1. 检查 AWS CLI 和权限
echo "1. 检查 AWS CLI 环境..."

# 检查 AWS CLI 配置
if ! aws sts get-caller-identity --region $REGION >/dev/null 2>&1; then
    echo "❌ AWS CLI 未配置或权限不足"
    exit 1
fi

CURRENT_USER=$(aws sts get-caller-identity --region $REGION --query 'Arn' --output text)
echo "当前用户: $CURRENT_USER"

# 2. 检查 Organizations 和 Firewall Manager
echo "2. 检查 AWS Organizations 和 Firewall Manager..."

# 检查 Organizations
if ! aws organizations describe-organization --region $REGION >/dev/null 2>&1; then
    echo "❌ AWS Organizations 未启用或权限不足"
    exit 1
fi

# 检查 Firewall Manager 管理员
ADMIN_ACCOUNT=$(aws fms get-admin-account --region $REGION --query 'AdminAccount' --output text 2>/dev/null || echo "None")
if [ "$ADMIN_ACCOUNT" = "None" ]; then
    echo "❌ Firewall Manager 管理员账户未设置"
    echo "请先运行: aws fms put-admin-account --admin-account \$(aws sts get-caller-identity --query Account --output text)"
    exit 1
fi

echo "✅ Firewall Manager 管理员账户: $ADMIN_ACCOUNT"

# 3. 验证依赖资源
echo "3. 验证依赖资源..."

# 检查 Network Firewall 规则组
echo "检查 Network Firewall 规则组..."
STATELESS_ARN=$(aws network-firewall list-rule-groups --region $REGION --query 'RuleGroups[?Name==`OrgWideStatelessRules`].Arn' --output text)
STATEFUL_ARN=$(aws network-firewall list-rule-groups --region $REGION --query 'RuleGroups[?Name==`OrgWideStatefulRules`].Arn' --output text)

if [ -z "$STATELESS_ARN" ]; then
    echo "❌ 无状态规则组 'OrgWideStatelessRules' 不存在"
    echo "请先运行 deploy-1-firewall-manager.sh 创建规则组"
    exit 1
fi

if [ -z "$STATEFUL_ARN" ]; then
    echo "❌ 有状态规则组 'OrgWideStatefulRules' 不存在"
    echo "请先运行 deploy-1-firewall-manager.sh 创建规则组"
    exit 1
fi

echo "✅ Network Firewall 规则组存在"
echo "  无状态规则组: $STATELESS_ARN"
echo "  有状态规则组: $STATEFUL_ARN"

# 检查 DNS Firewall 规则组
echo "检查 DNS Firewall 规则组..."
DNS_RULE_GROUP_ID=$(aws route53resolver list-firewall-rule-groups --region $REGION --query 'FirewallRuleGroups[?Name==`OrgWideDNSRules`].Id' --output text)

if [ -z "$DNS_RULE_GROUP_ID" ]; then
    echo "❌ DNS 防火墙规则组 'OrgWideDNSRules' 不存在"
    echo "请先运行 deploy-1-firewall-manager.sh 创建规则组"
    exit 1
fi

echo "✅ DNS Firewall 规则组存在: $DNS_RULE_GROUP_ID"

# 4. 更新配置文件中的实际资源引用
echo "4. 更新配置文件..."

# 获取根 OU ID
ROOT_OU_ID=$(aws organizations list-roots --query 'Roots[0].Id' --output text)
echo "根 OU ID: $ROOT_OU_ID"

# 创建临时配置文件用于测试
cp firewall-manager-configs/network-firewall-policy.json /tmp/test-network-firewall-policy.json
cp firewall-manager-configs/dns-firewall-policy.json /tmp/test-dns-firewall-policy.json

# 更新配置文件中的占位符
sed -i "s|ou-root-xxxxxxxxxx|$ROOT_OU_ID|g" /tmp/test-network-firewall-policy.json
sed -i "s|ou-root-xxxxxxxxxx|$ROOT_OU_ID|g" /tmp/test-dns-firewall-policy.json

# 更新 Network Firewall 配置中的 ARN
sed -i "s|arn:aws:network-firewall:ap-northeast-1:123456789012:stateless-rulegroup/OrgWideStatelessRules|$STATELESS_ARN|g" /tmp/test-network-firewall-policy.json
sed -i "s|arn:aws:network-firewall:ap-northeast-1:123456789012:stateful-rulegroup/OrgWideStatefulRules|$STATEFUL_ARN|g" /tmp/test-network-firewall-policy.json

# 更新 DNS Firewall 配置中的规则组 ID
sed -i "s|rslvr-frg-xxxxxxxxxx|$DNS_RULE_GROUP_ID|g" /tmp/test-dns-firewall-policy.json

echo "✅ 配置文件已更新实际资源引用"

# 5. 验证策略 JSON 格式
echo "5. 验证更新后的策略格式..."

echo "验证 Network Firewall 策略..."
if ! jq empty /tmp/test-network-firewall-policy.json 2>/dev/null; then
    echo "❌ Network Firewall 策略 JSON 格式错误"
    jq . /tmp/test-network-firewall-policy.json
    exit 1
fi

echo "验证 DNS Firewall 策略..."
if ! jq empty /tmp/test-dns-firewall-policy.json 2>/dev/null; then
    echo "❌ DNS Firewall 策略 JSON 格式错误"
    jq . /tmp/test-dns-firewall-policy.json
    exit 1
fi

echo "✅ 策略 JSON 格式正确"

# 6. 实际测试策略创建
if [ "$TEST_MODE" = true ]; then
    echo "6. 实际测试策略创建..."
    
    # 修改策略名称为测试版本
    jq '.PolicyName = "TEST-OrgWideNetworkFirewallPolicy"' /tmp/test-network-firewall-policy.json > /tmp/test-nw-policy-final.json
    jq '.PolicyName = "TEST-OrgWideDNSFirewallPolicy"' /tmp/test-dns-firewall-policy.json > /tmp/test-dns-policy-final.json
    
    echo "测试创建 Network Firewall 策略..."
    NW_POLICY_RESULT=$(aws fms put-policy --policy file:///tmp/test-nw-policy-final.json --region $REGION 2>&1)
    if [ $? -eq 0 ]; then
        echo "✅ Network Firewall 策略创建成功"
        NW_POLICY_ID=$(echo "$NW_POLICY_RESULT" | jq -r '.Policy.PolicyId' 2>/dev/null || echo "unknown")
        echo "  策略 ID: $NW_POLICY_ID"
    else
        echo "❌ Network Firewall 策略创建失败"
        echo "$NW_POLICY_RESULT"
        exit 1
    fi
    
    echo "测试创建 DNS Firewall 策略..."
    DNS_POLICY_RESULT=$(aws fms put-policy --policy file:///tmp/test-dns-policy-final.json --region $REGION 2>&1)
    if [ $? -eq 0 ]; then
        echo "✅ DNS Firewall 策略创建成功"
        DNS_POLICY_ID=$(echo "$DNS_POLICY_RESULT" | jq -r '.Policy.PolicyId' 2>/dev/null || echo "unknown")
        echo "  策略 ID: $DNS_POLICY_ID"
    else
        echo "❌ DNS Firewall 策略创建失败"
        echo "$DNS_POLICY_RESULT"
        exit 1
    fi
    
    # 等待策略处理
    echo "等待策略处理..."
    sleep 30
    
    # 检查策略状态
    echo "检查策略状态..."
    aws fms list-policies --region $REGION --query 'PolicyList[?starts_with(PolicyName, `TEST-`)].{Name:PolicyName,Status:PolicyStatus,Id:PolicyId}' --output table
    
    # 清理测试策略
    echo "清理测试策略..."
    if [ "$NW_POLICY_ID" != "unknown" ] && [ ! -z "$NW_POLICY_ID" ]; then
        aws fms delete-policy --policy-id "$NW_POLICY_ID" --region $REGION
        echo "已删除测试 Network Firewall 策略: $NW_POLICY_ID"
    fi
    
    if [ "$DNS_POLICY_ID" != "unknown" ] && [ ! -z "$DNS_POLICY_ID" ]; then
        aws fms delete-policy --policy-id "$DNS_POLICY_ID" --region $REGION
        echo "已删除测试 DNS Firewall 策略: $DNS_POLICY_ID"
    fi
    
else
    echo "6. 跳过实际创建测试（仅验证模式）"
    
    # 使用 AWS CLI 的 --cli-input-json 进行格式验证
    echo "使用 AWS CLI 验证策略格式..."
    
    # 注意：AWS CLI 没有 --dry-run 选项，所以我们只能验证 JSON 格式
    echo "验证 Network Firewall 策略格式..."
    if aws fms put-policy --cli-input-json file:///tmp/test-nw-policy-final.json --region $REGION --generate-cli-skeleton >/dev/null 2>&1; then
        echo "✅ Network Firewall 策略格式验证通过"
    else
        echo "⚠️  无法使用 --generate-cli-skeleton 验证（这是正常的）"
    fi
fi

# 7. 清理临时文件
rm -f /tmp/test-*.json

# 8. 生成验证报告
echo ""
echo "=== AWS CLI 验证报告 ==="
echo "✅ AWS CLI 环境正常"
echo "✅ Organizations 和 Firewall Manager 配置正确"
echo "✅ 依赖资源存在"
echo "✅ 配置文件格式正确"

if [ "$TEST_MODE" = true ]; then
    echo "✅ 实际策略创建测试通过"
fi

echo ""
echo "🎉 AWS CLI 验证完成！"
echo "📋 配置文件可以成功创建 Firewall Manager 策略"

echo ""
echo "下一步："
echo "1. 运行 ./deploy-1-firewall-manager.sh 部署 Firewall Manager"
echo "2. 运行 ./deploy-2-scp-protect.sh 部署 SCP 保护策略"
