# Firewall Manager VPC 要求和最佳实践

## 🎯 **核心要求**

### 1. **AWS Config 前置条件**

必需的资源类型：
```bash
resourceTypes=[
    "AWS::EC2::VPC", "AWS::EC2::Subnet", "AWS::EC2::InternetGateway",
    "AWS::EC2::RouteTable", "AWS::NetworkFirewall::Firewall",
    "AWS::NetworkFirewall::RuleGroup", "AWS::NetworkFirewall::FirewallPolicy",
    "AWS::Route53Resolver::FirewallRuleGroupAssociation",
    "AWS::Route53Resolver::FirewallRuleGroup", "AWS::Route53Resolver::FirewallDomainList"
]
```

### 2. **子网空间要求**

- 防火墙子网需要 **/28 CIDR 块**（16个IP）
- **每个 AZ 需要独立的防火墙子网**
- **子网分配不能碎片化**

### 3. **allowedIPV4CidrList 配置**

**🚨 注意事项**: Firewall Manager 策略中的 `allowedIPV4CidrList` 决定防火墙部署位置

#### 重要限制：
- **只支持 /28 CIDR 范围** - 不能使用 /16、/24 等其他掩码
- **必须精确匹配** - 防火墙只会在指定的 /28 范围内部署
- **新增限制** - 新的 CIDR 只能添加到列表末尾，不能修改现有项

#### 配置示例：
```json
{
  "allowedIPV4CidrList": [
    "10.0.0.0/28",   // 覆盖 10.0.0.0-10.0.0.15
    "10.0.1.0/28",   // 覆盖 10.0.1.0-10.0.1.15  
    "10.0.2.0/28"    // 覆盖 10.0.2.0-10.0.2.15
  ]
}
```

#### 常见错误：
- ❌ **错误**: `"allowedIPV4CidrList": ["10.0.0.0/16"]` - 不支持 /16
- ❌ **错误**: 子网是 `10.0.1.0/24`，但 allowedIPV4CidrList 只有 `10.0.0.0/28`
- ❌ **CIDR重叠**: allowedIPV4CidrList 包含 `10.0.1.0/28`，但VPC中已有 `10.0.1.0/24` 子网
- ✅ **正确**: 子网是 `10.0.1.0/24`，allowedIPV4CidrList 包含 `10.0.1.16/28` (避免重叠)

### 4. **网络架构要求**

- **至少一个公有子网**（有 Internet Gateway 路由）
- **默认路由必需** - VPC必须有 `0.0.0.0/0 -> Internet Gateway` 路由
- **多 AZ 部署**（推荐至少2个AZ）

**🚨 重要**: Firewall Manager 只在有默认路由的VPC中部署防火墙！

## 🔍 **问题排查**

| 错误信息 | 原因 | 解决方案 |
|----------|------|----------|
| `Cannot create AWS Config rule` | Config Recorder 未配置 | 配置完整的 Config Recorder |
| `Unable to create a subnet` | **CIDR重叠或空间不足** | **避免/28范围与现有子网重叠** |
| **某个 VPC 总是报错** | **allowedIPV4CidrList 不包含 172.31.x.x** | **添加排除标签 `VpcType=exclude`** |
| **合规但无防火墙实例** | **缺少默认路由或CIDR不匹配** | **添加0.0.0.0/0路由，检查CIDR配置** |
| `Only /28 CIDR ranges are supported` | 使用了非 /28 掩码 | 只使用 /28 CIDR 范围 |
| `CIDR conflicts with another subnet` | **防火墙/28与用户子网重叠** | **使用.16/28避免与.0/24重叠** |

### 合规但未部署防火墙
如果策略显示 `COMPLIANT` 但没有防火墙实例，检查：
1. `allowedIPV4CidrList` 是否覆盖了实际的子网范围
2. 子网 CIDR 是否与允许的 /28 范围重叠
3. **VPC是否有默认路由** (0.0.0.0/0 -> Internet Gateway)


## ✅ **推荐 VPC 设计**

### 简洁双 AZ 设计（推荐）
```
VPC: 10.0.0.0/16  ← 避免与默认VPC(172.31.x.x)冲突
├── 公有子网 1: 10.0.1.0/24 (ap-northeast-1a)
├── 公有子网 2: 10.0.2.0/24 (ap-northeast-1c)  
├── 防火墙子网 1: 10.0.0.0/28 ← Firewall Manager 自动创建
├── 防火墙子网 2: 10.0.1.16/28 ← 避免与10.0.1.0/24重叠
└── 防火墙子网 3: 10.0.2.16/28 ← 避免与10.0.2.0/24重叠

路由表配置:
├── 默认路由: 0.0.0.0/0 -> Internet Gateway ← 必需！
└── 本地路由: 10.0.0.0/16 -> local
```

**关键设计原则**:
1. **CIDR 对齐**: 确保子网范围与 `allowedIPV4CidrList` 中的 /28 范围重叠
2. **避免重叠**: 使用 .16/28 避免与常见的 .0/24 用户子网重叠
3. **避免默认网段**: 使用 10.x.x.x 而不是 172.31.x.x
4. **默认路由必需**: 必须有 0.0.0.0/0 -> IGW 路由

### 🎯 **最佳实践**

1. **CIDR 策略对齐** - 设计VPC时先确定 `allowedIPV4CidrList`，确保子网与 /28 范围重叠
2. **避免CIDR重叠** - 使用 .16/28 范围避免与常见的 .0/24 用户子网重叠
3. **默认路由必需** - 确保VPC有 0.0.0.0/0 -> Internet Gateway 路由
4. **使用 10.x.x.x 网段** - 避免与默认 VPC (172.31.x.x) 冲突
5. **预留连续空间** - 为防火墙子网预留连续的 /28 空间
6. **避免过度分割** - 使用简洁的 CIDR 规划
7. **Config 优先** - 确保 Config 完全配置后再部署策略
8. **排除不兼容VPC** - 对默认VPC和问题VPC使用排除标签

## 🧾 **参考脚本**
```bash
# 创建 VPC
aws ec2 create-vpc --cidr-block 10.0.0.0/16 \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=FirewallManager-VPC}]'

# 创建子网 (避免与防火墙子网重叠)
aws ec2 create-subnet --vpc-id vpc-xxx --cidr-block 10.0.1.0/24 --availability-zone ap-northeast-1a
aws ec2 create-subnet --vpc-id vpc-xxx --cidr-block 10.0.2.0/24 --availability-zone ap-northeast-1c

# 创建并关联 Internet Gateway
aws ec2 create-internet-gateway
aws ec2 attach-internet-gateway --vpc-id vpc-xxx --internet-gateway-id igw-xxx

# 添加默认路由 (关键步骤!)
aws ec2 create-route --route-table-id rtb-xxx --destination-cidr-block 0.0.0.0/0 --gateway-id igw-xxx
```

## 🔍 **快速验证**

```bash
# 检查 Config 状态
aws configservice describe-configuration-recorder-status --region ap-northeast-1

# 检查合规状态
aws fms list-compliance-status --policy-id POLICY_ID --region ap-northeast-1

# 检查防火墙实例
aws network-firewall list-firewalls --region ap-northeast-1

# 验证默认路由 (关键!)
aws ec2 describe-route-tables --filters "Name=vpc-id,Values=vpc-xxx" \
  --query 'RouteTables[*].Routes[?DestinationCidrBlock==`0.0.0.0/0`]'

# 检查CIDR重叠
aws ec2 describe-subnets --filters "Name=vpc-id,Values=vpc-xxx" \
  --query 'Subnets[*].[CidrBlock,AvailabilityZone,Tags[?Key==`Name`].Value|[0]]'
```

## 📊 **成功指标**

- 合规状态：`"ComplianceStatus": "COMPLIANT"`
- 防火墙实例：`FMManagedNetworkFirewall{PolicyName}{PolicyId}{VPCId}`
- 错误信息：`"IssueInfoMap": {}` (空)
