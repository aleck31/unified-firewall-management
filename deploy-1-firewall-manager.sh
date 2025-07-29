#!/bin/bash

# AWS Firewall Manager 部署脚本
# 仅部署 Firewall Manager 策略，不包含 SCP

set -e

# 配置变量 - 请根据实际环境修改
REGION="ap-northeast-1"               # 替换为你的区域

echo "=== AWS Firewall Manager 部署开始 ==="

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

# 2. 启用资源共享
echo "2. 启用 AWS RAM 资源共享..."
aws ram enable-sharing-with-aws-organization --region $REGION 2>/dev/null || {
    echo "⚠️  RAM 资源共享可能已启用或在当前区域不可用"
    echo "继续执行部署..."
}

# 3. 设置 Firewall Manager 管理员账户
echo "3. 检查 Firewall Manager 管理员账户..."

# 检查是否已经设置了管理员账户
CURRENT_ADMIN=$(aws fms get-admin-account --region $REGION --query 'AdminAccount' --output text 2>/dev/null || echo "None")

if [ "$CURRENT_ADMIN" = "$ADMIN_ACCOUNT_ID" ]; then
    echo "✅ 当前账户已经是 Firewall Manager 管理员账户"
elif [ "$CURRENT_ADMIN" != "None" ] && [ "$CURRENT_ADMIN" != "null" ]; then
    echo "⚠️  检测到其他账户 ($CURRENT_ADMIN) 已设置为管理员"
    echo "如需更改，请先撤销现有管理员账户"
    echo "继续使用现有管理员账户..."
else
    echo "设置 Firewall Manager 管理员账户..."
    aws fms put-admin-account --admin-account $ADMIN_ACCOUNT_ID --region $REGION
    
    # 等待管理员账户设置完成
    echo "等待管理员账户设置完成..."
    sleep 30
fi

# 4. 验证管理员账户
echo "4. 验证管理员账户设置..."
aws fms get-admin-account --region $REGION

# 5. 创建 Network Firewall 规则组
echo "5. 创建 Network Firewall 规则组..."

# 创建无状态规则组配置
cat > stateless-rules.json << 'EOF'
{
  "RulesSource": {
    "StatelessRulesAndCustomActions": {
      "StatelessRules": [
        {
          "RuleDefinition": {
            "MatchAttributes": {
              "Sources": [{"AddressDefinition": "0.0.0.0/0"}],
              "Destinations": [{"AddressDefinition": "0.0.0.0/0"}],
              "SourcePorts": [{"FromPort": 1, "ToPort": 65535}],
              "DestinationPorts": [{"FromPort": 80, "ToPort": 80}],
              "Protocols": [6]
            },
            "Actions": ["aws:forward_to_sfe"]
          },
          "Priority": 1
        }
      ]
    }
  }
}
EOF

aws network-firewall create-rule-group \
  --rule-group-name "OrgWideStatelessRules" \
  --type STATELESS \
  --capacity 100 \
  --rule-group file://stateless-rules.json \
  --region $REGION || echo "无状态规则组可能已存在"

# 创建有状态规则组配置
cat > stateful-rules.json << 'EOF'
{
  "RulesSource": {
    "RulesString": "drop tcp any any -> any 22 (msg:\"Block SSH from external\"; sid:1; rev:1;)\npass tcp any any -> any 443 (msg:\"Allow HTTPS\"; sid:2; rev:1;)"
  }
}
EOF

aws network-firewall create-rule-group \
  --rule-group-name "OrgWideStatefulRules" \
  --type STATEFUL \
  --capacity 100 \
  --rule-group file://stateful-rules.json \
  --region $REGION || echo "有状态规则组可能已存在"

# 6. 创建 DNS Firewall 规则组
echo "6. 创建 DNS Firewall 规则组..."

# 创建域名列表
echo "创建域名列表..."
aws route53resolver create-firewall-domain-list \
  --name "BlockedDomainsList" \
  --domains "example.com" "badsite.org" "www.wicar.org" \
  --region $REGION 2>/dev/null || echo "域名列表可能已存在"

# 获取域名列表ID
echo "获取域名列表ID..."
DOMAIN_LIST_ID=$(aws route53resolver list-firewall-domain-lists \
  --region $REGION \
  --query 'FirewallDomainLists[?Name==`BlockedDomainsList`].Id' \
  --output text)

if [ -z "$DOMAIN_LIST_ID" ] || [ "$DOMAIN_LIST_ID" = "None" ]; then
  echo "❌ 无法获取域名列表ID，请检查域名列表是否创建成功"
  exit 1
fi

echo "域名列表ID: $DOMAIN_LIST_ID"

# 创建 DNS 防火墙规则组
echo "创建 DNS 防火墙规则组..."
RULE_GROUP_ID=$(aws route53resolver create-firewall-rule-group \
  --name "OrgWideDNSRules" \
  --creator-request-id $(uuidgen) \
  --region $REGION \
  --query 'FirewallRuleGroup.Id' \
  --output text 2>/dev/null)

if [ -z "$RULE_GROUP_ID" ] || [ "$RULE_GROUP_ID" = "None" ]; then
  # 如果创建失败，尝试获取现有的规则组
  echo "规则组可能已存在，尝试获取现有规则组..."
  RULE_GROUP_ID=$(aws route53resolver list-firewall-rule-groups \
    --region $REGION \
    --query 'FirewallRuleGroups[?Name==`OrgWideDNSRules`].Id' \
    --output text)
fi

if [ -z "$RULE_GROUP_ID" ] || [ "$RULE_GROUP_ID" = "None" ]; then
  echo "❌ 无法获取DNS规则组ID"
  exit 1
fi

echo "DNS 规则组 ID: $RULE_GROUP_ID"

# 添加规则到规则组
echo "添加规则到规则组..."
aws route53resolver create-firewall-rule \
  --creator-request-id $(uuidgen) \
  --firewall-rule-group-id "$RULE_GROUP_ID" \
  --firewall-domain-list-id "$DOMAIN_LIST_ID" \
  --priority 100 \
  --action BLOCK \
  --name "BlockMalwareDomains" \
  --region $REGION 2>/dev/null || echo "DNS 规则可能已存在"

# 7. 准备 Firewall Manager 策略配置
echo "7. 准备 Firewall Manager 策略配置..."

# 获取规则组 ARN
STATELESS_ARN=$(aws network-firewall describe-rule-group \
  --rule-group-name "OrgWideStatelessRules" \
  --type STATELESS \
  --region $REGION \
  --query 'RuleGroupResponse.RuleGroupArn' \
  --output text)

STATEFUL_ARN=$(aws network-firewall describe-rule-group \
  --rule-group-name "OrgWideStatefulRules" \
  --type STATEFUL \
  --region $REGION \
  --query 'RuleGroupResponse.RuleGroupArn' \
  --output text)

echo "无状态规则组 ARN: $STATELESS_ARN"
echo "有状态规则组 ARN: $STATEFUL_ARN"

# 确保配置目录存在
mkdir -p firewall-manager-configs

# 更新 Network Firewall 策略配置
echo "更新 Network Firewall 策略配置..."
sed -i "s|ou-root-xxxxxxxxxx|$ROOT_OU_ID|g" firewall-manager-configs/network-firewall-policy.json
sed -i "s|arn:aws:network-firewall:ap-northeast-1:123456789012:stateless-rulegroup/OrgWideStatelessRules|$STATELESS_ARN|g" firewall-manager-configs/network-firewall-policy.json
sed -i "s|arn:aws:network-firewall:ap-northeast-1:123456789012:stateful-rulegroup/OrgWideStatefulRules|$STATEFUL_ARN|g" firewall-manager-configs/network-firewall-policy.json

# 更新 DNS Firewall 策略配置
echo "更新 DNS Firewall 策略配置..."
sed -i "s|ou-root-xxxxxxxxxx|$ROOT_OU_ID|g" firewall-manager-configs/dns-firewall-policy.json
sed -i "s|rslvr-frg-xxxxxxxxxx|$RULE_GROUP_ID|g" firewall-manager-configs/dns-firewall-policy.json

# 8. 部署 Firewall Manager 策略
echo "8. 部署 Firewall Manager 策略..."

# 部署 Network Firewall 策略
echo "部署 Network Firewall 策略..."
aws fms put-policy \
  --policy file://firewall-manager-configs/network-firewall-policy.json \
  --region $REGION

# 部署 DNS Firewall 策略
echo "部署 DNS Firewall 策略..."
aws fms put-policy \
  --policy file://firewall-manager-configs/dns-firewall-policy.json \
  --region $REGION

# 等待策略部署
echo "等待策略部署完成..."
sleep 60

# 9. 验证部署
echo "9. 验证部署状态..."

echo "=== Firewall Manager 策略状态 ==="
aws fms list-policies --region $REGION --query 'PolicyList[*].[PolicyName,PolicyStatus]' --output table

echo "=== Firewall Manager 部署完成 ==="
echo "✅ Network Firewall 策略已部署"
echo "✅ DNS Firewall 策略已部署"
echo ""
echo "监控地址:"
echo "- Firewall Manager: https://console.aws.amazon.com/wafv2/fms"
echo ""
echo "下一步:"
echo "1. 在 AWS 控制台中验证策略状态"
echo "2. 如需部署 SCP 保护策略，请运行 ./deploy-2-scp-protect.sh"
echo "3. 测试防火墙功能是否正常工作"

# 清理临时文件
rm -f stateless-rules.json stateful-rules.json

echo "Firewall Manager 部署脚本执行完成！"
