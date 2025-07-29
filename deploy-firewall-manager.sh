#!/bin/bash

# AWS 多账号防火墙统一管理完整部署脚本
# 实现 Firewall Manager + SCP 双重保护方案

set -e

# 配置变量 - 请根据实际环境修改
REGION="us-east-1"               # 替换为你的区域

echo "=== AWS 多账号防火墙统一管理部署开始 ==="

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
aws ram enable-sharing-with-aws-organization --region $REGION

# 3. 设置 Firewall Manager 管理员账户
echo "3. 设置 Firewall Manager 管理员账户..."
aws fms put-admin-account --admin-account $ADMIN_ACCOUNT_ID --region $REGION

# 等待管理员账户设置完成
echo "等待管理员账户设置完成..."
sleep 30

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
aws route53resolver create-firewall-domain-list \
  --name "BlockedDomainsList" \
  --domains "malware.example.com" "phishing.example.com" "suspicious.example.com" \
  --region $REGION || echo "域名列表可能已存在"

# 获取域名列表ID
DOMAIN_LIST_ID=$(aws route53resolver list-firewall-domain-lists \
  --region $REGION \
  --query 'FirewallDomainLists[?Name==`BlockedDomainsList`].Id' \
  --output text)

# 创建 DNS 防火墙规则组
RULE_GROUP_ID=$(aws route53resolver create-firewall-rule-group \
  --name "OrgWideDNSRules" \
  --creator-request-id $(uuidgen) \
  --region $REGION \
  --query 'FirewallRuleGroup.Id' \
  --output text 2>/dev/null || \
  aws route53resolver list-firewall-rule-groups \
  --region $REGION \
  --query 'FirewallRuleGroups[?Name==`OrgWideDNSRules`].Id' \
  --output text)

# 添加规则到规则组
aws route53resolver create-firewall-rule \
  --creator-request-id $(uuidgen) \
  --firewall-rule-group-id $RULE_GROUP_ID \
  --firewall-domain-list-id $DOMAIN_LIST_ID \
  --priority 100 \
  --action BLOCK \
  --name "BlockMalwareDomains" \
  --region $REGION || echo "DNS 规则可能已存在"

echo "DNS 规则组 ID: $RULE_GROUP_ID"

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

# 确保配置目录存在
mkdir -p firewall-manager-configs

# 更新 Network Firewall 策略配置
sed -i "s|ou-root-xxxxxxxxxx|$ROOT_OU_ID|g" firewall-manager-configs/network-firewall-policy.json
sed -i "s|arn:aws:network-firewall:us-east-1:123456789012:stateless-rulegroup/OrgWideStatelessRules|$STATELESS_ARN|g" firewall-manager-configs/network-firewall-policy.json
sed -i "s|arn:aws:network-firewall:us-east-1:123456789012:stateful-rulegroup/OrgWideStatefulRules|$STATEFUL_ARN|g" firewall-manager-configs/network-firewall-policy.json

# 更新 DNS Firewall 策略配置
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

# 9. 创建和部署 SCP 策略
echo "9. 创建和部署 SCP 保护策略..."

# 创建 SCP 策略
SCP_POLICY_ID=$(aws organizations create-policy \
  --name "FirewallProtectionPolicy" \
  --description "Prevent unauthorized firewall modifications while allowing Firewall Manager" \
  --type SERVICE_CONTROL_POLICY \
  --content file://firewall-protection-scp.json \
  --query 'Policy.PolicySummary.Id' \
  --output text)

echo "SCP 策略 ID: $SCP_POLICY_ID"

# 应用 SCP 策略到根 OU
aws organizations attach-policy \
  --policy-id $SCP_POLICY_ID \
  --target-id $ROOT_OU_ID

echo "SCP 策略已应用到根 OU"

# 10. 验证部署
echo "10. 验证部署状态..."
sleep 30  # 等待策略生效

echo "=== Firewall Manager 策略状态 ==="
aws fms list-policies --region $REGION --query 'PolicyList[*].[PolicyName,PolicyStatus]' --output table

echo "=== SCP 策略应用状态 ==="
aws organizations list-policies-for-target \
  --target-id $ROOT_OU_ID \
  --filter SERVICE_CONTROL_POLICY \
  --query 'Policies[*].[Name,Id]' \
  --output table

echo "=== 部署完成 ==="
echo "✅ Firewall Manager 策略已部署并生效"
echo "✅ SCP 保护策略已应用到所有成员账户"
echo "✅ 双重保护机制已建立"
echo ""
echo "监控地址:"
echo "- Firewall Manager: https://console.aws.amazon.com/wafv2/fms"
echo "- Organizations: https://console.aws.amazon.com/organizations"
echo ""
echo "下一步:"
echo "1. 在 AWS 控制台中验证策略状态"
echo "2. 测试成员账户是否被正确阻止修改防火墙"
echo "3. 设置监控和告警"

# 清理临时文件
rm -f stateless-rules.json stateful-rules.json

echo "部署脚本执行完成！"
