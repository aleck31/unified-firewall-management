# AWS 多账号防火墙统一管理完整实施方案

## 方案概述
本方案通过 **AWS Firewall Manager + SCP 双重保护** 实现：
- 统一管理多个 AWS 账号的 Network Firewall 和 DNS Firewall 策略
- 阻止子账号擅自修改防火墙配置
- 确保组织级安全策略的一致性和强制执行

## 架构原理
- **Firewall Manager**：提供统一部署、管理和自动修复
- **SCP (Service Control Policies)**：提供实时权限控制，防止未授权修改
- **双重保护**：确保既有集中管理又有强制执行

## 支持的防火墙类型
✅ **AWS Network Firewall** - 网络层防火墙  
✅ **Route53 Resolver DNS Firewall** - DNS 层防火墙  
✅ **AWS WAF** - Web 应用防火墙  
✅ **VPC Security Groups** - 安全组  
✅ **Network ACLs** - 网络访问控制列表  

## 完整实施步骤

### 阶段一：环境准备（根账号 admin 用户执行）

#### 1.1 验证 AWS Organizations 环境
```bash
# 确保已启用 AWS Organizations
aws organizations describe-organization

# 获取根 OU ID（后续配置需要）
ROOT_OU_ID=$(aws organizations list-roots --query 'Roots[0].Id' --output text)
echo "根 OU ID: $ROOT_OU_ID"

# 启用资源共享（必需）
aws ram enable-sharing-with-aws-organization
```

#### 1.2 设置 Firewall Manager 管理员账户
```bash
# 获取当前账户ID
ADMIN_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# 设置 Firewall Manager 管理员账户
aws fms put-admin-account --admin-account $ADMIN_ACCOUNT_ID

# 验证管理员账户设置
aws fms get-admin-account
```

#### 1.3 验证必需的 IAM 权限
确保根账号 admin 用户具有以下权限：
- `FMSServiceRolePolicy`
- `AWSNetworkFirewallServiceRolePolicy` 
- `Route53ResolverServiceRolePolicy`
- `AWSOrganizationsFullAccess`

### 阶段二：创建防火墙规则组（根账号 admin 用户执行）

#### 2.1 创建 Network Firewall 规则组

```bash
# 创建无状态规则组配置文件
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

# 创建无状态规则组
aws network-firewall create-rule-group \
  --rule-group-name "OrgWideStatelessRules" \
  --type STATELESS \
  --capacity 100 \
  --rule-group file://stateless-rules.json

# 创建有状态规则组配置文件
cat > stateful-rules.json << 'EOF'
{
  "RulesSource": {
    "RulesString": "drop tcp any any -> any 22 (msg:\"Block SSH from external\"; sid:1; rev:1;)\npass tcp any any -> any 443 (msg:\"Allow HTTPS\"; sid:2; rev:1;)"
  }
}
EOF

# 创建有状态规则组
aws network-firewall create-rule-group \
  --rule-group-name "OrgWideStatefulRules" \
  --type STATEFUL \
  --capacity 100 \
  --rule-group file://stateful-rules.json
```

#### 2.2 创建 DNS Firewall 规则组

```bash
# 创建域名列表
aws route53resolver create-firewall-domain-list \
  --name "BlockedDomainsList" \
  --domains "example.com" "badsite.org" "www.wicar.org"

# 获取域名列表ID
DOMAIN_LIST_ID=$(aws route53resolver list-firewall-domain-lists \
  --query 'FirewallDomainLists[?Name==`BlockedDomainsList`].Id' \
  --output text)

# 创建 DNS 防火墙规则组
RULE_GROUP_ID=$(aws route53resolver create-firewall-rule-group \
  --name "OrgWideDNSRules" \
  --creator-request-id $(uuidgen) \
  --query 'FirewallRuleGroup.Id' \
  --output text)

# 添加阻止规则到规则组
aws route53resolver create-firewall-rule \
  --creator-request-id $(uuidgen) \
  --firewall-rule-group-id $RULE_GROUP_ID \
  --firewall-domain-list-id $DOMAIN_LIST_ID \
  --priority 100 \
  --action BLOCK \
  --name "BlockMalwareDomains"

echo "DNS 规则组 ID: $RULE_GROUP_ID"
```

### 阶段三：部署 Firewall Manager 策略（根账号 admin 用户执行）

#### 3.1 准备策略配置文件
使用提供的配置文件模板，更新相关参数：

```bash
# 获取规则组 ARN
STATELESS_ARN=$(aws network-firewall describe-rule-group \
  --rule-group-name "OrgWideStatelessRules" \
  --type STATELESS \
  --query 'RuleGroupResponse.RuleGroupArn' \
  --output text)

STATEFUL_ARN=$(aws network-firewall describe-rule-group \
  --rule-group-name "OrgWideStatefulRules" \
  --type STATEFUL \
  --query 'RuleGroupResponse.RuleGroupArn' \
  --output text)

# 更新配置文件中的占位符
sed -i "s|ou-root-xxxxxxxxxx|$ROOT_OU_ID|g" firewall-manager-configs/*.json
sed -i "s|arn:aws:network-firewall:ap-northeast-1:123456789012:stateless-rulegroup/OrgWideStatelessRules|$STATELESS_ARN|g" firewall-manager-configs/network-firewall-policy.json
sed -i "s|arn:aws:network-firewall:ap-northeast-1:123456789012:stateful-rulegroup/OrgWideStatefulRules|$STATEFUL_ARN|g" firewall-manager-configs/network-firewall-policy.json
sed -i "s|rslvr-frg-xxxxxxxxxx|$RULE_GROUP_ID|g" firewall-manager-configs/dns-firewall-policy.json
```

#### 3.2 部署策略

#### Network Firewall 策略
```json
{
  "PolicyName": "OrgWideNetworkFirewallPolicy",
  "SecurityServicePolicyData": {
    "Type": "NETWORK_FIREWALL",
    "ManagedServiceData": "{\"type\":\"NETWORK_FIREWALL\",\"networkFirewallStatelessRuleGroupReferences\":[{\"resourceArn\":\"arn:aws:network-firewall:ap-northeast-1:account:stateless-rulegroup/OrgWideStatelessRules\",\"priority\":100}],\"networkFirewallStatefulRuleGroupReferences\":[{\"resourceArn\":\"arn:aws:network-firewall:ap-northeast-1:account:stateful-rulegroup/OrgWideStatefulRules\"}],\"networkFirewallStatelessDefaultActions\":[\"aws:forward_to_sfe\"],\"networkFirewallStatelessFragmentDefaultActions\":[\"aws:forward_to_sfe\"],\"networkFirewallOrchestrationConfig\":{\"singleFirewallEndpointPerVPC\":false,\"allowedIPV4CidrList\":[\"0.0.0.0/0\"]}}"
  },
  "ResourceType": "AWS::EC2::VPC",
  "IncludeMap": {
    "OU": ["ou-root-xxxxxxxxxx"]
  },
  "ExcludeResourceTags": false,
  "RemediationEnabled": true,
  "DeleteUnusedFMManagedResources": false
}
```

#### DNS Firewall 策略
```json
{
  "PolicyName": "OrgWideDNSFirewallPolicy",
  "SecurityServicePolicyData": {
    "Type": "DNS_FIREWALL",
    "ManagedServiceData": "{\"type\":\"DNS_FIREWALL\",\"preProcessRuleGroups\":[{\"ruleGroupId\":\"<DNS_RULE_GROUP_ID>\",\"priority\":100}],\"postProcessRuleGroups\":[]}"
  },
  "ResourceType": "AWS::EC2::VPC",
  "IncludeMap": {
    "OU": ["ou-root-xxxxxxxxxx"]
  },
  "ExcludeResourceTags": false,
  "RemediationEnabled": true,
  "DeleteUnusedFMManagedResources": false
}
```

```bash
# 先在测试 OU 部署（推荐）
# 如果有测试 OU，先更新配置文件指向测试 OU
# sed -i "s|$ROOT_OU_ID|ou-test-xxxxxxxxxx|g" firewall-manager-configs/*.json

# 部署 Network Firewall 策略
echo "部署 Network Firewall 策略..."
aws fms put-policy --policy file://firewall-manager-configs/network-firewall-policy.json

# 部署 DNS Firewall 策略  
echo "部署 DNS Firewall 策略..."
aws fms put-policy --policy file://firewall-manager-configs/dns-firewall-policy.json

# 等待策略部署完成
echo "等待策略部署完成..."
sleep 60

# 验证策略状态
aws fms list-policies --query 'PolicyList[*].[PolicyName,PolicyStatus]' --output table
```

### 阶段四：配置 SCP 保护策略（根账号 admin 用户执行）

#### 4.1 更新 SCP 策略文件
需要为 Firewall Manager 服务角色添加例外条件：

```bash
# 更新 SCP 策略文件，添加 Firewall Manager 服务角色例外
cat > firewall-protection-scp-updated.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyNetworkFirewallModification",
      "Effect": "Deny",
      "Action": [
        "network-firewall:DeleteFirewall",
        "network-firewall:DeleteFirewallPolicy",
        "network-firewall:DeleteRuleGroup",
        "network-firewall:UpdateFirewallDeleteProtection",
        "network-firewall:UpdateFirewallPolicy",
        "network-firewall:UpdateFirewallPolicyChangeProtection",
        "network-firewall:UpdateRuleGroup",
        "network-firewall:DisassociateSubnets"
      ],
      "Resource": "*",
      "Condition": {
        "StringNotEquals": {
          "aws:PrincipalArn": [
            "arn:aws:iam::*:role/aws-service-role/fms.amazonaws.com/AWSServiceRoleForFMS",
            "arn:aws:iam::*:role/FirewallManagerServiceRole",
            "arn:aws:iam::*:role/SecurityAdminRole"
          ]
        }
      }
    },
    {
      "Sid": "DenyDNSFirewallModification", 
      "Effect": "Deny",
      "Action": [
        "route53resolver:DeleteFirewallDomainList",
        "route53resolver:DeleteFirewallRule",
        "route53resolver:DeleteFirewallRuleGroup",
        "route53resolver:DisassociateFirewallRuleGroup",
        "route53resolver:UpdateFirewallDomains",
        "route53resolver:UpdateFirewallRule",
        "route53resolver:UpdateFirewallRuleGroupAssociation"
      ],
      "Resource": "*",
      "Condition": {
        "StringNotEquals": {
          "aws:PrincipalArn": [
            "arn:aws:iam::*:role/aws-service-role/fms.amazonaws.com/AWSServiceRoleForFMS",
            "arn:aws:iam::*:role/FirewallManagerServiceRole",
            "arn:aws:iam::*:role/SecurityAdminRole"
          ]
        }
      }
    }
  ]
}
EOF
```

#### 4.2 创建并应用 SCP 策略

```bash
# 创建 SCP 策略
SCP_POLICY_ID=$(aws organizations create-policy \
  --name "FirewallProtectionPolicy" \
  --description "Prevent unauthorized firewall modifications while allowing Firewall Manager" \
  --type SERVICE_CONTROL_POLICY \
  --content file://firewall-protection-scp-updated.json \
  --query 'Policy.PolicySummary.Id' \
  --output text)

echo "SCP 策略 ID: $SCP_POLICY_ID"

# 应用 SCP 策略到根 OU（影响所有成员账户）
aws organizations attach-policy \
  --policy-id $SCP_POLICY_ID \
  --target-id $ROOT_OU_ID

echo "SCP 策略已应用到根 OU"
```

### 阶段五：验证和测试

#### 5.1 验证 Firewall Manager 策略部署

```bash
# 检查策略状态
echo "=== Firewall Manager 策略状态 ==="
aws fms list-policies --query 'PolicyList[*].[PolicyName,PolicyStatus]' --output table

# 检查合规状态
echo "=== 合规状态检查 ==="
POLICY_IDS=$(aws fms list-policies --query 'PolicyList[*].PolicyId' --output text)
for POLICY_ID in $POLICY_IDS; do
  echo "策略 $POLICY_ID 的合规状态:"
  aws fms list-compliance-status --policy-id $POLICY_ID --query 'PolicyComplianceStatusList[*].[MemberAccount,PolicyComplianceStatus.ComplianceStatus]' --output table
done
```

#### 5.2 验证 SCP 策略生效

```bash
# 检查 SCP 策略应用状态
echo "=== SCP 策略应用状态 ==="
aws organizations list-policies-for-target \
  --target-id $ROOT_OU_ID \
  --filter SERVICE_CONTROL_POLICY \
  --query 'Policies[*].[Name,Id]' \
  --output table
```

#### 5.3 功能测试

**测试1：验证 Firewall Manager 仍可正常工作**
```bash
# Firewall Manager 应该能够正常更新策略（不被 SCP 阻止）
aws fms get-policy --policy-id <NETWORK_FIREWALL_POLICY_ID>
```

**测试2：验证普通用户被正确阻止**
在成员账户中使用普通用户身份尝试：
```bash
# 这个操作应该被 SCP 拒绝
aws network-firewall update-firewall-policy \
  --firewall-policy-arn <ARN> \
  --firewall-policy <POLICY>
# 预期结果: AccessDenied 错误
```

## 持续管理和监控

### 1. 日常监控任务

#### 策略合规性监控
```bash
# 每日合规性检查脚本
#!/bin/bash
echo "=== 每日防火墙合规性检查 $(date) ==="

# 检查所有 Firewall Manager 策略状态
aws fms list-policies --query 'PolicyList[?PolicyStatus!=`ACTIVE`].[PolicyName,PolicyStatus]' --output table

# 检查不合规资源
POLICY_IDS=$(aws fms list-policies --query 'PolicyList[*].PolicyId' --output text)
for POLICY_ID in $POLICY_IDS; do
  NON_COMPLIANT=$(aws fms list-compliance-status --policy-id $POLICY_ID --query 'PolicyComplianceStatusList[?PolicyComplianceStatus.ComplianceStatus!=`COMPLIANT`].MemberAccount' --output text)
  if [ ! -z "$NON_COMPLIANT" ]; then
    echo "策略 $POLICY_ID 存在不合规账户: $NON_COMPLIANT"
  fi
done
```

#### SCP 拒绝事件监控
```bash
# 监控被 SCP 阻止的防火墙操作
aws logs filter-log-events \
  --log-group-name CloudTrail/OrganizationTrail \
  --start-time $(date -d '1 day ago' +%s)000 \
  --filter-pattern '{ $.errorCode = "AccessDenied" && ($.eventSource = "network-firewall.amazonaws.com" || $.eventSource = "route53resolver.amazonaws.com") }' \
  --query 'events[*].[eventTime,sourceIPAddress,userIdentity.type,eventName]' \
  --output table
```

### 2. 告警设置

#### CloudWatch 告警配置
```bash
# 设置 Firewall Manager 合规性告警
aws cloudwatch put-metric-alarm \
  --alarm-name "FirewallManagerNonCompliance" \
  --alarm-description "Alert when firewall policies are non-compliant" \
  --metric-name ComplianceByPolicy \
  --namespace AWS/FMS \
  --statistic Average \
  --period 300 \
  --threshold 95 \
  --comparison-operator LessThanThreshold \
  --alarm-actions arn:aws:sns:region:account:firewall-alerts

# 设置 SCP 拒绝事件告警
aws logs put-metric-filter \
  --log-group-name CloudTrail/OrganizationTrail \
  --filter-name FirewallSCPDenials \
  --filter-pattern '{ $.errorCode = "AccessDenied" && ($.eventSource = "network-firewall.amazonaws.com" || $.eventSource = "route53resolver.amazonaws.com") }' \
  --metric-transformations \
    metricName=FirewallSCPDenials,metricNamespace=Security/SCP,metricValue=1
```

## 故障排除

### 常见问题及解决方案

#### 问题1：Firewall Manager 策略部署失败
**症状**：
```
AccessDenied: User is not authorized to perform: network-firewall:UpdateFirewallPolicy
```

**原因**：SCP 策略阻止了 Firewall Manager 服务角色

**解决方案**：
```bash
# 检查 SCP 策略是否包含 Firewall Manager 服务角色例外
aws organizations describe-policy --policy-id <SCP_POLICY_ID>

# 如果没有例外，更新 SCP 策略添加以下条件：
"Condition": {
  "StringNotEquals": {
    "aws:PrincipalArn": [
      "arn:aws:iam::*:role/aws-service-role/fms.amazonaws.com/AWSServiceRoleForFMS"
    ]
  }
}
```

#### 问题2：资源共享失败
**症状**：
```
Cannot share rule groups across accounts
```

**解决方案**：
```bash
# 确保启用了 AWS RAM 资源共享
aws ram enable-sharing-with-aws-organization

# 检查 SCP 是否阻止了 RAM 操作
# 如果需要，在 SCP 中添加 RAM 权限例外
```

#### 问题3：策略合规性检查失败
**症状**：资源显示为不合规但无法自动修复

**解决方案**：
```bash
# 手动触发合规性检查
aws fms get-compliance-detail --policy-id <POLICY_ID> --member-account <ACCOUNT_ID>

# 检查目标资源是否存在
aws ec2 describe-vpcs --region <REGION>

# 如果需要，手动触发策略重新应用
aws fms put-policy --policy file://updated-policy.json
```

## 最佳实践

### 1. 分阶段部署策略
- **测试先行**：先在测试 OU 部署，验证无误后再推广到生产环境
- **逐步扩展**：从小范围开始，逐步扩展到整个组织
- **回滚准备**：保留策略版本，确保可以快速回滚

### 2. 权限管理
- **最小权限原则**：只授予必要的权限
- **定期审查**：定期审查和更新 SCP 策略中的例外条件
- **紧急访问**：为紧急情况预留 SecurityAdminRole 访问权限

### 3. 监控和合规
- **持续监控**：设置自动化监控和告警
- **定期审计**：定期检查策略合规性和配置漂移
- **文档更新**：及时更新文档和操作程序

### 4. 成本优化
- **集中式部署**：优先使用集中式 Network Firewall 部署模式
- **容量规划**：合理配置规则组容量，避免过度配置
- **定期清理**：定期审查和清理未使用的规则和资源

## 应急响应程序

### 发现未授权修改时的响应步骤
1. **立即评估**：确定修改的范围和潜在影响
2. **隔离风险**：必要时暂停相关账户或用户权限
3. **恢复配置**：通过 Firewall Manager 强制重新应用策略
4. **调查原因**：分析 CloudTrail 日志确定根本原因
5. **加强控制**：更新 SCP 策略防止类似事件再次发生

## 自动化脚本

### 分步部署脚本
本方案提供两个独立的部署脚本，支持分步部署：

#### 步骤1：部署 Firewall Manager
```bash
# 设置环境变量
export REGION="ap-northeast-1"  # 替换为你的区域

# 执行 Firewall Manager 部署
chmod +x deploy-1-firewall-manager.sh
./deploy-1-firewall-manager.sh
```

#### 步骤2：部署 SCP 保护策略
```bash
# 执行 SCP 策略部署
chmod +x deploy-2-scp-protect.sh
./deploy-2-scp-protect.sh
```

### 脚本功能说明
- **`deploy-1-firewall-manager.sh`**：自动化执行阶段一到阶段三的所有步骤
- **`deploy-2-scp-protect.sh`**：自动化执行阶段四的 SCP 策略部署

### 部署顺序建议
1. **先部署 Firewall Manager**：确保防火墙策略正常工作
2. **验证功能**：测试防火墙策略是否按预期工作
3. **再部署 SCP**：添加权限保护，防止未授权修改

## 总结

### 方案优势
| 方面 | 传统方式 | 本方案 (Firewall Manager + SCP) |
|------|---------|--------------------------------|
| **部署效率** | 逐个账户配置 | ✅ 一次配置，全组织应用 |
| **一致性保证** | 人工维护，易出错 | ✅ 自动化保证一致性 |
| **权限控制** | 依赖账户级权限 | ✅ 组织级强制控制 |
| **合规监控** | 手动检查 | ✅ 自动监控和修复 |
| **成本效益** | 高运维成本 | ✅ 显著降低管理成本 |
| **安全防护** | 可能被绕过 | ✅ 多层防护，难以绕过 |

### 实施效果
通过本方案，你将实现：

✅ **统一管理**：在根账号集中管理所有防火墙策略  
✅ **强制执行**：通过 SCP 实时阻止未授权修改  
✅ **自动化运维**：新账户和资源自动应用策略  
✅ **持续合规**：自动监控和修复不合规资源  
✅ **安全可控**：多层防护确保配置不被恶意修改  

### 关键成功因素
1. **正确的权限配置**：确保 SCP 策略包含 Firewall Manager 服务角色例外
2. **充分的测试验证**：在生产环境部署前进行充分测试
3. **持续的监控维护**：建立完善的监控和告警机制
4. **完善的应急预案**：制定清晰的故障处理和应急响应流程

通过遵循本实施方案，你可以建立一个安全、高效、可扩展的多账号防火墙管理体系，彻底解决防火墙配置分散管理和安全风险问题！
