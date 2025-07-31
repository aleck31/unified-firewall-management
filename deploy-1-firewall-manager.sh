#!/bin/bash

# AWS Firewall Manager 部署脚本
# 专注于 Firewall Manager 策略部署，前置条件请先运行 deploy-0-prerequisites.sh

set -e

# 配置变量 - 请根据实际环境修改
REGION="ap-northeast-1"               # 替换为你的区域

echo "=== AWS Firewall Manager 策略部署开始 ==="

# 1. 获取环境信息
echo "1. 获取环境信息..."
ADMIN_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ROOT_OU_ID=$(aws organizations list-roots --query 'Roots[0].Id' --output text)

echo "管理员账户ID: $ADMIN_ACCOUNT_ID"
echo "根 OU ID: $ROOT_OU_ID"

# 检查现有的子 OU
echo "检查现有的组织单元..."
EXISTING_OUS=$(aws organizations list-organizational-units-for-parent \
  --parent-id $ROOT_OU_ID \
  --query 'OrganizationalUnits[*].[Id,Name]' \
  --output table)

if [ ! -z "$EXISTING_OUS" ] && [ "$EXISTING_OUS" != "None" ]; then
  echo "发现现有的组织单元:"
  echo "$EXISTING_OUS"
  echo ""
  echo "请选择要使用的 OU ID，或输入 'new' 创建新的安全管理 OU:"
  read -p "OU ID (或 'new'): " USER_CHOICE
  
  if [ "$USER_CHOICE" = "new" ]; then
    # 创建新的子 OU
    echo "创建新的安全管理子 OU..."
    TARGET_OU_ID=$(aws organizations create-organizational-unit \
      --parent-id $ROOT_OU_ID \
      --name "SecurityOU" \
      --query 'OrganizationalUnit.Id' \
      --output text)
    echo "已创建安全管理 OU ID: $TARGET_OU_ID"
  else
    TARGET_OU_ID="$USER_CHOICE"
    echo "使用现有 OU ID: $TARGET_OU_ID"
  fi
else
  echo "未发现现有的子 OU，将创建新的安全管理 OU..."
  TARGET_OU_ID=$(aws organizations create-organizational-unit \
    --parent-id $ROOT_OU_ID \
    --name "SecurityOU" \
    --query 'OrganizationalUnit.Id' \
    --output text)
  echo "已创建安全管理 OU ID: $TARGET_OU_ID"
fi

if [ -z "$TARGET_OU_ID" ] || [ "$TARGET_OU_ID" = "None" ]; then
  echo "❌ 无法获取或创建安全管理 OU"
  exit 1
fi

# 2. 创建 Network Firewall 规则组
echo "2. 创建 Network Firewall 规则组..."

# 创建无状态规则组
echo "创建无状态规则组..."
aws network-firewall create-rule-group \
  --rule-group-name "OrgWideStatelessRules" \
  --type STATELESS \
  --capacity 100 \
  --rule-group '{
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
  }' \
  --region $REGION || echo "无状态规则组可能已存在"

# 创建有状态规则组
echo "创建有状态规则组..."
aws network-firewall create-rule-group \
  --rule-group-name "OrgWideStatefulRules" \
  --type STATEFUL \
  --capacity 100 \
  --rule-group '{
    "RulesSource": {
      "RulesString": "drop tcp any any -> any 22 (msg:\"Block SSH from external\"; sid:1; rev:1;)\npass tcp any any -> any 443 (msg:\"Allow HTTPS\"; sid:2; rev:1;)"
    }
  }' \
  --region $REGION || echo "有状态规则组可能已存在"

# 3. 创建 DNS Firewall 规则组
echo "3. 创建 DNS Firewall 规则组..."

# 创建域名列表
echo "创建域名列表..."
aws route53resolver create-firewall-domain-list \
  --name "BlockedDomainsList" \
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

# 添加域名到列表
echo "添加域名到列表..."
aws route53resolver update-firewall-domains \
  --firewall-domain-list-id "$DOMAIN_LIST_ID" \
  --operation ADD \
  --domains "badsite.org" "example.com" "www.wicar.org" \
  --region $REGION 2>/dev/null || echo "域名可能已存在"

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
  --priority 10 \
  --action BLOCK \
  --name "BlockMalwareDomains" \
  --region $REGION 2>/dev/null || echo "DNS 规则可能已存在"

# 4. 准备 Firewall Manager 策略配置
echo "4. 准备 Firewall Manager 策略配置..."

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
sed -i "s|ou-id-12345678|$TARGET_OU_ID|g" firewall-manager-configs/network-firewall-policy.json
sed -i "s|arn:aws:network-firewall:ap-northeast-1:123456789012:stateless-rulegroup/OrgWideStatelessRules|$STATELESS_ARN|g" firewall-manager-configs/network-firewall-policy.json
sed -i "s|arn:aws:network-firewall:ap-northeast-1:123456789012:stateful-rulegroup/OrgWideStatefulRules|$STATEFUL_ARN|g" firewall-manager-configs/network-firewall-policy.json

# 更新 DNS Firewall 策略配置
echo "更新 DNS Firewall 策略配置..."
sed -i "s|ou-id-12345678|$TARGET_OU_ID|g" firewall-manager-configs/dns-firewall-policy.json
sed -i "s|rslvr-frg-xxxxxxxxxx|$RULE_GROUP_ID|g" firewall-manager-configs/dns-firewall-policy.json

# 5. 部署 Firewall Manager 策略
echo "5. 部署 Firewall Manager 策略..."

# 部署 Network Firewall 策略
echo "部署 Network Firewall 策略..."
NW_POLICY_RESULT=$(aws fms put-policy \
  --policy file://firewall-manager-configs/network-firewall-policy.json \
  --region $REGION 2>&1)

if [ $? -eq 0 ]; then
  NW_POLICY_ID=$(echo "$NW_POLICY_RESULT" | jq -r '.Policy.PolicyId' 2>/dev/null || echo "unknown")
  echo "✅ Network Firewall 策略创建成功，策略 ID: $NW_POLICY_ID"
else
  echo "❌ Network Firewall 策略创建失败:"
  echo "$NW_POLICY_RESULT"
  exit 1
fi

# 部署 DNS Firewall 策略
echo "部署 DNS Firewall 策略..."
DNS_POLICY_RESULT=$(aws fms put-policy \
  --policy file://firewall-manager-configs/dns-firewall-policy.json \
  --region $REGION 2>&1)

if [ $? -eq 0 ]; then
  DNS_POLICY_ID=$(echo "$DNS_POLICY_RESULT" | jq -r '.Policy.PolicyId' 2>/dev/null || echo "unknown")
  echo "✅ DNS Firewall 策略创建成功，策略 ID: $DNS_POLICY_ID"
else
  echo "❌ DNS Firewall 策略创建失败:"
  echo "$DNS_POLICY_RESULT"
  exit 1
fi

# 等待策略部署
echo "等待策略部署完成..."
sleep 60

# 6. 验证部署和资源共享
echo "6. 验证部署状态..."

echo "=== Firewall Manager 策略状态 ==="
aws fms list-policies --region $REGION --query 'PolicyList[*].[PolicyName,PolicyStatus]' --output table

# 检查策略合规状态
echo "=== 策略合规状态检查 ==="
if [ "$NW_POLICY_ID" != "unknown" ] && [ ! -z "$NW_POLICY_ID" ]; then
  echo "Network Firewall 策略合规状态:"
  aws fms list-compliance-status --policy-id "$NW_POLICY_ID" --region $REGION \
    --query 'PolicyComplianceStatusList[*].[MemberAccount,PolicyComplianceStatus.ComplianceStatus]' \
    --output table 2>/dev/null || echo "合规状态检查中..."
fi

if [ "$DNS_POLICY_ID" != "unknown" ] && [ ! -z "$DNS_POLICY_ID" ]; then
  echo "DNS Firewall 策略合规状态:"
  aws fms list-compliance-status --policy-id "$DNS_POLICY_ID" --region $REGION \
    --query 'PolicyComplianceStatusList[*].[MemberAccount,PolicyComplianceStatus.ComplianceStatus]' \
    --output table 2>/dev/null || echo "合规状态检查中..."
fi

# 检查资源共享状态
echo "=== 资源共享状态 ==="
echo "检查 Network Firewall 规则组共享:"
aws ram get-resource-shares --resource-owner SELF --region $REGION \
  --query 'resourceShares[?name==`FMS-*`].[name,status]' \
  --output table 2>/dev/null || echo "资源共享信息获取中..."

echo "=== Firewall Manager 部署完成 ==="
echo "✅ Network Firewall 策略已部署 (ID: $NW_POLICY_ID)"
echo "✅ DNS Firewall 策略已部署 (ID: $DNS_POLICY_ID)"
echo ""
echo "📊 部署状态:"
echo "- 策略将自动应用到指定的 OU: $TARGET_OU_ID"
echo "- 规则组将通过 AWS RAM 自动共享到成员账户"
echo "- 防火墙将在成员账户的 VPC 中自动创建"
echo ""
echo "🔍 监控地址:"
echo "- Firewall Manager: https://console.aws.amazon.com/wafv2/fms"
echo "- AWS RAM: https://console.aws.amazon.com/ram"
echo ""
echo "⏰ 注意事项:"
echo "- 策略部署可能需要几分钟时间"
echo "- 合规状态检查可能需要10-15分钟"
echo "- 可以通过 Firewall Manager 控制台监控部署进度"
echo ""
echo "下一步:"
echo "1. 在 AWS 控制台中验证策略状态"
echo "2. 如需部署 SCP 保护策略，请运行 ./deploy-2-scp-protect.sh"
echo "3. 测试防火墙功能是否正常工作"

echo "Firewall Manager 部署脚本执行完成！"
