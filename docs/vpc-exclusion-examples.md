# Firewall Manager VPC 排除配置指南

## 🎯 **概述**

在生产环境中，某些 VPC 可能不需要应用 Network Firewall 策略。根据 AWS 官方文档，Firewall Manager 提供了多种排除机制来满足这种需求。

## 📋 **官方支持的排除机制**

根据 [AWS Firewall Manager Policy API](https://docs.aws.amazon.com/fms/2018-01-01/APIReference/API_Policy.html) 文档，支持以下排除方式：

| 排除方式 | API 字段 | 适用范围 | 推荐度 |
|----------|----------|----------|--------|
| **账号/OU 排除** | `IncludeMap`/`ExcludeMap` | 整个账号或组织单元 | ⭐⭐⭐⭐⭐ |
| **资源标签排除** | `ResourceTags`+`ExcludeResourceTags` | 基于标签的资源级控制 | ⭐⭐⭐⭐ |

## 🔧 **方法 1：账号/OU 级别排除（最常用）**

### 使用 ExcludeMap 排除特定账号

```json
{
  "PolicyName": "OrgWideNetworkFirewallPolicy",
  "SecurityServicePolicyData": {
    "Type": "NETWORK_FIREWALL",
    "ManagedServiceData": "..."
  },
  "ResourceType": "AWS::EC2::VPC",
  "IncludeMap": {
    "ORG_UNIT": ["ou-2949-qksovdg7"]
  },
  "ExcludeMap": {
    "ACCOUNT": ["123456789012", "987654321098"]
  },
  "RemediationEnabled": true,
  "ExcludeResourceTags": false
}
```

### 使用 ExcludeMap 排除特定 OU

```json
{
  "PolicyName": "OrgWideNetworkFirewallPolicy",
  "IncludeMap": {
    "ORG_UNIT": ["ou-root-12345678"]
  },
  "ExcludeMap": {
    "ORG_UNIT": ["ou-legacy-87654321"]
  }
}
```

**⚠️ 重要限制**：
- 不能同时指定 `IncludeMap` 和 `ExcludeMap`
- 如果指定了 `IncludeMap`，Firewall Manager 只应用到包含的账号/OU
- 如果没有指定 `IncludeMap`，则应用到所有账号，除了 `ExcludeMap` 中的账号/OU

## 🔧 **方法 2：资源标签排除**

### 官方 API 字段说明

根据 [Policy API 文档](https://docs.aws.amazon.com/fms/2018-01-01/APIReference/API_Policy.html)：

- **`ResourceTags`**: 指定标签数组
- **`ExcludeResourceTags`**: 布尔值
  - `True`: 排除带有指定标签的资源
  - `False`: 只包含带有指定标签的资源

### 步骤 1：给 VPC 添加排除标签

```bash
# 给不需要防火墙的 VPC 添加排除标签
aws ec2 create-tags \
  --resources vpc-xxxxxxxxx \
  --tags Key=FirewallExempt,Value=true \
  --region ap-northeast-1

# 验证标签已添加
aws ec2 describe-vpcs \
  --vpc-ids vpc-xxxxxxxxx \
  --query 'Vpcs[*].Tags' \
  --region ap-northeast-1
```

### 步骤 2：配置策略排除带标签的资源

```json
{
  "PolicyName": "OrgWideNetworkFirewallPolicy",
  "SecurityServicePolicyData": {
    "Type": "NETWORK_FIREWALL",
    "ManagedServiceData": "..."
  },
  "ResourceType": "AWS::EC2::VPC",
  "ResourceTags": [
    {
      "Key": "FirewallExempt",
      "Value": "true"
    }
  ],
  "ExcludeResourceTags": true,
  "IncludeMap": {
    "ORG_UNIT": ["ou-2949-qksovdg7"]
  },
  "RemediationEnabled": true
}
```

### 步骤 3：应用更新的策略

```bash
# 获取当前策略的 UpdateToken
UPDATE_TOKEN=$(aws fms get-policy \
  --policy-id e702738a-7bce-43e3-bdfc-2a6b98d61de6 \
  --region ap-northeast-1 \
  --query 'Policy.PolicyUpdateToken' --output text)

# 更新策略
aws fms put-policy \
  --policy file://updated-policy.json \
  --region ap-northeast-1
```

## 🔧 **方法 3：只包含特定标签的资源**

```json
{
  "PolicyName": "OrgWideNetworkFirewallPolicy",
  "ResourceType": "AWS::EC2::VPC",
  "ResourceTags": [
    {
      "Key": "FirewallRequired",
      "Value": "true"
    }
  ],
  "ExcludeResourceTags": false,
  "IncludeMap": {
    "ORG_UNIT": ["ou-2949-qksovdg7"]
  }
}
```

**说明**：`ExcludeResourceTags: false` 表示只有带有指定标签的 VPC 才会应用策略。

## 📋 **实际应用场景**

### 场景 1：生产账号中的混合 VPC（推荐使用标签排除）

```
🏢 生产账号 (123456789012)
├── 🌐 VPC-Web (需要防火墙) 
│   └── 🏷️ 无特殊标签
├── 🌐 VPC-Database (需要防火墙)
│   └── 🏷️ 无特殊标签
└── 🌐 VPC-Legacy (不需要防火墙)
    └── 🏷️ 标签: FirewallExempt=true
```

**策略配置**：
```json
{
  "ResourceTags": [{"Key": "FirewallExempt", "Value": "true"}],
  "ExcludeResourceTags": true
}
```

### 场景 2：整个账号不需要防火墙（推荐使用账号排除）

```
🏢 组织结构
├── 📊 Production OU
│   ├── Account-A (需要防火墙)
│   └── Account-B (需要防火墙)
└── 📊 Legacy OU  
    └── Account-C (不需要防火墙)
```

**策略配置**：
```json
{
  "IncludeMap": {"ORG_UNIT": ["ou-production-12345"]},
  "ExcludeMap": {"ORG_UNIT": ["ou-legacy-67890"]}
}
```

## 🔍 **验证排除配置**

### 检查策略应用范围

```bash
# 检查策略合规状态
aws fms list-compliance-status \
  --policy-id e702738a-7bce-43e3-bdfc-2a6b98d61de6 \
  --region ap-northeast-1

# 检查特定账号的合规详情
aws fms get-compliance-detail \
  --policy-id e702738a-7bce-43e3-bdfc-2a6b98d61de6 \
  --member-account 123456789012 \
  --region ap-northeast-1
```

### 验证 VPC 标签

```bash
# 检查 VPC 标签
aws ec2 describe-vpcs \
  --filters Name=tag:FirewallExempt,Values=true \
  --query 'Vpcs[*].[VpcId,Tags]' \
  --region ap-northeast-1
```

## ⚠️ **重要注意事项**

### API 限制
- **不能同时使用 `IncludeMap` 和 `ExcludeMap`**
- **`ResourceTags` 和 `ExcludeResourceTags` 必须配合使用**
- **标签匹配区分大小写**

### 安全考虑
- 排除的 VPC 将失去 Network Firewall 保护
- 需要确保有其他安全控制措施
- 定期审查排除的资源和原因

### 策略更新
- 标签变更后策略会在下次评估时生效
- 策略更新可能需要几分钟传播
- 监控合规状态变化

### 标签管理最佳实践
- 建立一致的标签命名约定
- 实施标签治理策略
- 定期审查和清理标签

## 📚 **相关文档**

### 排除机制相关
- [AWS Firewall Manager Policy API](https://docs.aws.amazon.com/fms/2018-01-01/APIReference/API_Policy.html)
- [ResourceTag API](https://docs.aws.amazon.com/fms/2018-01-01/APIReference/API_ResourceTag.html)
- [OrganizationalUnitScope API](https://docs.aws.amazon.com/fms/2018-01-01/APIReference/API_OrganizationalUnitScope.html)

### 其他相关功能
- [Firewall Manager Resource Sets 使用指南](./firewall-manager-resource-sets-guide.md) - 用于导入现有防火墙的高级功能

---

**总结**：对于 VPC 级别的精确排除，**资源标签排除**是最实用的方法。账号/OU 级别排除适用于更大范围的排除需求。如需管理现有防火墙，请参考 Resource Sets 专门文档。
