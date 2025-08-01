# AWS Firewall Manager 统一管理防火墙规则最佳实践

## 🎯 **概述**

本文档基于实际测试验证，总结了使用 AWS Firewall Manager 统一管理多账号 Network Firewall 规则的最佳实践。通过根账号或者委托管理员账号模式，Firewall Manager 管理员可以在一处修改防火墙规则，自动同步到整个组织的所有防火墙实例。

## 🏗️ **架构设计**

### 核心组件
```
🏢 AWS Organizations 管理账号 (Root Account)
├── 🔧 创建 Firewall Manager 管理员账号
├── 📋 委托权限管理
└── 🛡️ SCP 保护策略
    └── 防止成员账号修改防火墙配置

👥 Firewall Manager 管理员账号 (Administrator Account)
├── 📋 规则组 (Rule Groups)
│   ├── OrgWideStatefulRules (有状态规则组)
│   └── OrgWideStatelessRules (无状态规则组)
├── 🔥 Firewall Manager 策略
│   └── OrgWideNetworkFirewallPolicy
└── 🔧 统一管理整个组织的防火墙

📊 组织单元 (Security OU)
├── 👥 成员账号 A
│   └── 🛡️ Network Firewall (自动部署)
├── 👥 成员账号 B
│   └── 🛡️ Network Firewall (自动部署)
└── 👥 成员账号 C
    └── 🛡️ Network Firewall (自动部署)
```

### 工作流程
```
👥 Firewall Manager 管理员账号
    ↓ 修改规则组
📋 OrgWideStatefulRules (规则组)
    ↓ 自动检测变化 (UpdateToken 机制)
🔥 OrgWideNetworkFirewallPolicy (Firewall Manager 策略)
    ↓ 自动同步到所有防火墙
🛡️ 所有 Security OU 内的防火墙实例
    ↓ 规则立即生效
🌐 全组织统一安全策略
```

## 📋 **运行机制**

根据 AWS 官方文档 [Using AWS Network Firewall policies in Firewall Manager](https://docs.aws.amazon.com/waf/latest/developerguide/network-firewall-policies.html)：

> **Important**  
> **You must have your Network Firewall rule groups defined.**  
> When you specify a new Network Firewall policy, you define the firewall policy the same as you do when you're using AWS Network Firewall directly. You specify the stateless rule groups to add, default stateless actions, and stateful rule groups. **Your rule groups must already exist in the Firewall Manager administrator account for you to include them in the policy.**

### 解读：
- **规则组必须存在于 Firewall Manager 管理员账号中**
- **不能直接引用其他账号的规则组**
- **管理员账号通过 Organizations 管理账号委托创建**

## ✅ **实践验证结果**

### 测试场景：阻断 HTTP 端口 80
| 步骤 | 操作 | 结果 | 状态 |
|------|------|------|------|
| **1. 修改规则组** | 在管理员账号修改 `OrgWideStatefulRules` | ✅ 成功更新 | **通过** |
| **2. 自动检测** | Firewall Manager 检测规则组变化 | ✅ UpdateToken 更新 | **通过** |
| **3. 自动同步** | 防火墙自动同步新规则 | ✅ SyncStatus: IN_SYNC | **通过** |
| **4. 规则生效** | 端口 80 被成功阻断 | ✅ 连接被拒绝 | **通过** |

## 🔧 **实施步骤**

### 前置条件：设置 Firewall Manager 管理员账号

#### 1. 在 Organizations 管理账号中委托管理员账号
```bash
# 设置 Firewall Manager 管理员账号（在根账号中执行）
aws fms put-admin-account --admin-account 123456789012

# 或通过 AWS Console：
# 1. 登录 Organizations 管理账号
# 2. 打开 Firewall Manager 控制台
# 3. Settings -> Create administrator account
# 4. 输入成员账号 ID 并配置管理范围
```

#### 2. 验证管理员账号设置
```bash
# 检查当前的 Firewall Manager 管理员账号
aws fms get-admin-account

# 列出所有管理员账号
aws fms list-admin-accounts-for-organization
```

### 主要实施步骤（在 Firewall Manager 管理员账号中执行）

#### 1. 创建规则组
```bash
# 创建有状态规则组（在管理员账号中执行）
aws network-firewall create-rule-group \
  --rule-group-name "OrgWideStatefulRules" \
  --type STATEFUL \
  --capacity 100 \
  --rule-group '{
    "RulesSource": {
      "RulesString": "pass tcp any any -> any 80 (msg:\"Allow HTTP\"; sid:1; rev:1;)\npass tcp any any -> any 443 (msg:\"Allow HTTPS\"; sid:2; rev:1;)\ndrop tcp any any -> any 22 (msg:\"Block SSH\"; sid:3; rev:1;)"
    }
  }'

# 创建无状态规则组（在管理员账号中执行）
aws network-firewall create-rule-group \
  --rule-group-name "OrgWideStatelessRules" \
  --type STATELESS \
  --capacity 100 \
  --rule-group '{
    "RulesSource": {
      "StatelessRulesAndCustomActions": {
        "StatelessRules": [{
          "RuleDefinition": {
            "MatchAttributes": {
              "DestinationPorts": [{"FromPort": 80, "ToPort": 80}],
              "Protocols": [6]
            },
            "Actions": ["aws:forward_to_sfe"]
          },
          "Priority": 1
        }]
      }
    }
  }'
```

#### 2. 创建 Firewall Manager 策略（在管理员账号中执行）
```bash
aws fms put-policy \
  --policy '{
    "PolicyName": "OrgWideNetworkFirewallPolicy",
    "SecurityServicePolicyData": {
      "Type": "NETWORK_FIREWALL",
      "ManagedServiceData": "{
        \"type\":\"NETWORK_FIREWALL\",
        \"networkFirewallStatelessRuleGroupReferences\":[{
          \"resourceARN\":\"arn:aws:network-firewall:region:account:stateless-rulegroup/OrgWideStatelessRules\",
          \"priority\":1
        }],
        \"networkFirewallStatelessDefaultActions\":[\"aws:forward_to_sfe\"],
        \"networkFirewallStatelessFragmentDefaultActions\":[\"aws:forward_to_sfe\"],
        \"networkFirewallStatefulRuleGroupReferences\":[{
          \"resourceARN\":\"arn:aws:network-firewall:region:account:stateful-rulegroup/OrgWideStatefulRules\"
        }]
      }"
    },
    "ResourceType": "AWS::EC2::VPC",
    "RemediationEnabled": true,
    "IncludeMap": {
      "ORG_UNIT": ["ou-xxxxxxxxx"]
    }
  }'
```

### 3. 部署 SCP 保护策略
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyNetworkFirewallModification",
      "Effect": "Deny",
      "Action": [
        "network-firewall:*"
      ],
      "Resource": "*",
      "Condition": {
        "StringNotEquals": {
          "aws:PrincipalServiceName": "fms.amazonaws.com"
        }
      }
    }
  ]
}
```

## 🔄 **策略更新机制与行为**

### 策略更新原理

当更新 Firewall Manager 策略时，系统采用"就地更新"而非"删除重建"的机制：

#### 🔍 **策略ID变更机制**
```
旧策略更新前：
├── 策略ID: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
├── 防火墙实例: FMManagedNetworkFirewall...xxxxxxxx...vpc-xxx
└── 合规状态: COMPLIANT

策略更新后：
├── 策略ID: yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy (新ID)
├── 防火墙实例: FMManagedNetworkFirewall...xxxxxxxx...vpc-xxx (保留)
├── 合规状态: VIOLATOR (临时状态)
└── 重新评估: 5-15分钟后恢复COMPLIANT
```

#### ✅ **防火墙实例保留行为**

| 组件 | 更新行为 | 说明 |
|------|----------|------|
| **防火墙实例** | ✅ **保留** | 物理防火墙继续运行，不会重建 |
| **防火墙子网** | ✅ **保留** | 网络拓扑保持不变 |
| **网络流量** | ✅ **持续过滤** | 安全防护不中断 |
| **策略关联** | ⚠️ **重新关联** | 新策略ID需要重新识别现有资源 |
| **合规状态** | ⚠️ **临时违规** | 重新评估期间显示违规，属正常现象 |

#### 🔧 **配置同步过程**
```
1. 策略更新触发
   ↓
2. 生成新策略ID
   ↓
3. 保留现有防火墙实例
   ↓
4. 重新评估资源范围
   ↓
5. 关联现有防火墙到新策略
   ↓
6. 同步配置变更（如有）
   ↓
7. 更新合规状态为COMPLIANT
```

### 实际验证结果

#### 📊 **策略更新前后对比**
```bash
# 更新前 - 防火墙正常运行
aws network-firewall describe-firewall \
  --firewall-name "FMManagedNetworkFirewall...xxxxxxxx...vpc-xxx"
# 状态: READY, ConfigurationSyncStateSummary: IN_SYNC

# 策略更新 (put-policy)
aws fms put-policy --policy file://updated-policy.json
# 结果: 新策略ID生成

# 更新后 - 防火墙仍然运行
aws network-firewall describe-firewall \
  --firewall-name "FMManagedNetworkFirewall...xxxxxxxx...vpc-xxx"
# 状态: 仍然是 READY, ConfigurationSyncStateSummary: IN_SYNC
# 证明: 防火墙实例未被删除重建
```

#### ⏰ **重新评估时间线**
| 时间点 | 策略状态 | 防火墙状态 | 合规状态 |
|--------|----------|------------|----------|
| **T+0** | 策略更新完成 | 防火墙正常运行 | 显示违规 |
| **T+2分钟** | 新策略生效 | 防火墙正常运行 | 仍显示违规 |
| **T+5分钟** | 重新评估中 | 防火墙正常运行 | 开始重新关联 |
| **T+10分钟** | 评估完成 | 防火墙正常运行 | 恢复合规 |

### DeleteUnusedFMManagedResources 参数

#### 🔧 **参数作用**
```json
{
  "DeleteUnusedFMManagedResources": false  // 推荐设置
}
```

| 参数值 | 行为 | 适用场景 |
|--------|------|----------|
| **false** | 保留所有 Firewall Manager 创建的资源 | 生产环境（推荐） |
| **true** | 删除不再被策略管理的资源 | 清理环境 |

#### ⚠️ **重要说明**
- **策略更新不会触发资源删除**：即使设置为 `true`，策略更新也不会删除现有防火墙
- **只有策略删除才会触发清理**：使用 `delete-policy` 时才会根据此参数决定是否清理资源
- **建议生产环境设置为 `false`**：避免意外删除重要的安全资源

### 最佳实践建议

#### ✅ **策略更新前**
1. **备份当前策略配置**
   ```bash
   aws fms get-policy --policy-id current-policy-id > backup-policy.json
   ```

2. **记录现有防火墙实例**
   ```bash
   aws network-firewall list-firewalls > current-firewalls.json
   ```

3. **检查当前合规状态**
   ```bash
   aws fms list-compliance-status --policy-id current-policy-id
   ```

#### ✅ **策略更新后**
1. **等待重新评估完成**（5-15分钟）
2. **验证防火墙实例状态**
   ```bash
   aws network-firewall describe-firewall --firewall-name firewall-name
   ```

3. **确认合规状态恢复**
   ```bash
   aws fms list-compliance-status --policy-id new-policy-id
   ```

4. **测试网络连通性**
   ```bash
   # 验证防火墙规则仍然生效
   curl -m 5 http://target-server:80
   ```

#### ⚠️ **注意事项**
- **临时违规状态是正常现象**：不要在重新评估期间进行额外操作
- **避免频繁更新策略**：给系统足够时间完成重新评估
- **监控防火墙日志**：确保安全规则持续生效
- **保持网络配置稳定**：策略更新期间避免修改网络拓扑

## 🔄 **日常管理操作**

### 更新防火墙规则（在 Firewall Manager 管理员账号中执行）
```bash
# 获取当前规则组的 UpdateToken
UPDATE_TOKEN=$(aws network-firewall describe-rule-group \
  --rule-group-name "OrgWideStatefulRules" \
  --type STATEFUL \
  --query 'UpdateToken' --output text)

# 更新规则组
aws network-firewall update-rule-group \
  --rule-group-name "OrgWideStatefulRules" \
  --type STATEFUL \
  --update-token $UPDATE_TOKEN \
  --rule-group '{
    "RulesSource": {
      "RulesString": "drop tcp any any -> any 80 (msg:\"Block HTTP\"; sid:1; rev:1;)\npass tcp any any -> any 443 (msg:\"Allow HTTPS\"; sid:2; rev:1;)"
    }
  }'
```

### 验证同步状态
```bash
# 检查防火墙同步状态（在任意有权限的账号中执行）
aws network-firewall describe-firewall \
  --firewall-name "YourFirewallName" \
  --query 'FirewallStatus.ConfigurationSyncStateSummary'

# 检查规则组关联状态（在管理员账号中执行）
aws network-firewall describe-rule-group \
  --rule-group-name "OrgWideStatefulRules" \
  --type STATEFUL \
  --query 'RuleGroupResponse.NumberOfAssociations'
```

### 跨账号管理最佳实践
```bash
# 1. 在管理员账号中设置配置文件
aws configure set profile.firewall-admin.region ap-northeast-1
aws configure set profile.firewall-admin.account 123456789012

# 2. 使用专用配置文件管理规则
aws network-firewall update-rule-group \
  --profile firewall-admin \
  --rule-group-name "OrgWideStatefulRules" \
  --type STATEFUL \
  --rule-group file://new-rules.json

# 3. 验证更新是否同步到其他账号
aws network-firewall describe-firewall \
  --profile member-account \
  --firewall-name "AutoCreatedFirewall" \
  --query 'FirewallStatus.SyncStates'
```

## 🎯 **关键优势**

### ✅ **委托管理模式**
- 专门的安全团队账号管理防火墙规则
- 与生产环境隔离，降低误操作风险
- 符合最小权限原则和职责分离

### ✅ **集中管理**
- 管理员账号一处修改，全组织生效
- 统一的安全策略管理
- 减少管理复杂性和配置漂移

### ✅ **自动同步**
- 无需手动干预
- 规则变更自动传播到所有防火墙
- UpdateToken 机制确保版本一致性

### ✅ **实时生效**
- 规则修改后立即在所有防火墙生效
- 同步状态可监控 (IN_SYNC)
- 支持回滚和版本控制

### ✅ **安全保护**
- 结合 SCP 策略防止成员账号擅自修改
- Firewall Manager 保留完全控制权限
- 符合企业合规要求

### ✅ **成本优化**
- 避免重复配置和管理工作
- 统一的资源标签和成本分配
- 自动化减少人工错误

## ⚠️ **注意事项**

### 权限要求
- 执行账号需要是 Organizations 的管理账号（用于委托管理员）
- Firewall Manager 管理员账号需要相应的防火墙管理权限
- 需要启用 AWS Config 和 Resource Access Manager
- 确保跨账号信任关系正确配置

### 管理员账号设置
- 选择专门的安全团队账号作为 Firewall Manager 管理员
- 配置适当的管理范围（账号、OU、区域、策略类型）
- 定期审查管理员权限和访问范围
- 建立管理员账号的访问控制和审计机制

### 网络配置
- 确保防火墙子网有正确的路由配置
- 验证 Internet Gateway 和 NAT Gateway 设置
- 检查安全组不会干扰测试
- 考虑跨区域部署的网络延迟

### 规则设计
- 使用明确的 PASS/DROP 规则
- 避免依赖默认行为
- 合理设置规则优先级
- 规则组必须在管理员账号中创建

### 监控和日志
- 启用防火墙日志记录
- 监控规则匹配情况
- 设置 CloudWatch 告警

## 🔍 **故障排除**

### 常见问题

1. **规则不生效**
   ```bash
   # 检查同步状态
   aws network-firewall describe-firewall --firewall-name "YourFirewall"
   
   # 检查规则组关联
   aws network-firewall describe-rule-group --rule-group-name "YourRuleGroup"
   ```

2. **防火墙策略冲突**
   ```bash
   # 列出所有 Firewall Manager 策略
   aws fms list-policies
   
   # 检查策略详情
   aws fms get-policy --policy-id "policy-id"
   ```

3. **网络连通性问题**
   ```bash
   # 检查路由表配置
   aws ec2 describe-route-tables --filters "Name=vpc-id,Values=vpc-xxxxxx"
   
   # 检查防火墙端点状态
   aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=vpc-xxxxxx"
   ```

## 📚 **参考文档**

### 核心服务文档
- [AWS Firewall Manager 用户指南](https://docs.aws.amazon.com/waf/latest/developerguide/fms-chapter.html)
- [AWS Network Firewall 开发者指南](https://docs.aws.amazon.com/network-firewall/latest/developerguide/)
- [AWS Organizations 用户指南](https://docs.aws.amazon.com/organizations/latest/userguide/)

### Firewall Manager 策略
- [使用 Network Firewall 策略](https://docs.aws.amazon.com/waf/latest/developerguide/network-firewall-policies.html)
- [Firewall Manager 策略创建](https://docs.aws.amazon.com/waf/latest/developerguide/create-policy.html#creating-firewall-manager-policy-for-network-firewall)
- [资源共享配置](https://docs.aws.amazon.com/waf/latest/developerguide/resource-sharing.html)

### Firewall Manager 管理员
- [创建 Firewall Manager 管理员账号](https://docs.aws.amazon.com/waf/latest/developerguide/fms-creating-administrators.html)
- [使用 Firewall Manager 管理员](https://docs.aws.amazon.com/waf/latest/developerguide/fms-administrators.html)
- [Firewall Manager 前置条件](https://docs.aws.amazon.com/waf/latest/developerguide/fms-prereq.html)

### Network Firewall 相关
- [管理规则组](https://docs.aws.amazon.com/network-firewall/latest/developerguide/rule-groups.html)
- [防火墙策略处理](https://docs.aws.amazon.com/network-firewall/latest/developerguide/firewall-policy-processing.html)
- [有状态和无状态规则引擎](https://docs.aws.amazon.com/network-firewall/latest/developerguide/firewall-rules-engines.html)
- [更新防火墙](https://docs.aws.amazon.com/network-firewall/latest/developerguide/firewall-updating.html)

### 规则组管理
- [有状态规则组](https://docs.aws.amazon.com/network-firewall/latest/developerguide/stateful-rule-groups-ips.html)
- [无状态规则组](https://docs.aws.amazon.com/network-firewall/latest/developerguide/stateless-rule-groups-standard.html)
- [Suricata 兼容规则](https://docs.aws.amazon.com/network-firewall/latest/developerguide/stateful-rule-groups-suricata.html)

### 安全和合规
- [服务控制策略 (SCP)](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html)
- [IAM 权限和策略](https://docs.aws.amazon.com/waf/latest/developerguide/fms-security.html)
- [日志记录和监控](https://docs.aws.amazon.com/network-firewall/latest/developerguide/firewall-logging.html)

### API 参考
- [Firewall Manager API 参考](https://docs.aws.amazon.com/fms/2018-01-01/APIReference/)
- [Network Firewall API 参考](https://docs.aws.amazon.com/network-firewall/latest/APIReference/)
- [AWS CLI 命令参考](https://docs.aws.amazon.com/cli/latest/reference/)

### 最佳实践和指南
- [AWS 安全最佳实践](https://docs.aws.amazon.com/security/latest/userguide/)
- [多账号安全策略](https://docs.aws.amazon.com/whitepapers/latest/organizing-your-aws-environment/security-ou-and-accounts.html)
- [网络安全设计模式](https://docs.aws.amazon.com/architecture-center/latest/networking/)

---

**注意**: 本文档基于AWS东京区域部署和测试经验编写，建议在生产环境实施前先在测试环境验证。
