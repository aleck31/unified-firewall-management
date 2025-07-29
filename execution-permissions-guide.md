# 执行权限需求说明

## 概述
本文档说明执行 AWS 多账号防火墙统一管理方案时的权限要求和用户角色限制。

## 权限要求分析

### ✅ 根账号管理员（推荐且必需）
**完全支持所有操作**，具备以下关键权限：

#### 必需的服务权限
- **AWS Organizations**：创建和管理 SCP 策略，应用到 OU
- **AWS Firewall Manager**：设置管理员账户，管理防火墙策略
- **AWS Network Firewall**：创建和管理规则组
- **Route53 Resolver**：创建和管理 DNS 防火墙规则
- **AWS RAM**：启用跨账户资源共享
- **Amazon EC2**：管理 VPC 和网络资源
- **AWS IAM**：管理服务链接角色

#### 详细权限列表
根据 AWS 官方文档，需要以下具体权限：

**Organizations 权限**：
```json
{
  "Effect": "Allow",
  "Action": [
    "organizations:DescribeOrganization",
    "organizations:ListRoots",
    "organizations:ListPolicies",
    "organizations:CreatePolicy",
    "organizations:AttachPolicy",
    "organizations:EnableAWSServiceAccess"
  ],
  "Resource": "*"
}
```

**Firewall Manager 权限**：
```json
{
  "Effect": "Allow", 
  "Action": [
    "fms:GetAdminAccount",
    "fms:PutAdminAccount",
    "fms:ListPolicies",
    "fms:PutPolicy",
    "fms:GetPolicy",
    "fms:GetComplianceDetail"
  ],
  "Resource": "*"
}
```

**Network Firewall 权限**：
```json
{
  "Effect": "Allow",
  "Action": [
    "network-firewall:*"
  ],
  "Resource": "*"
}
```

**Route53 Resolver 权限**：
```json
{
  "Effect": "Allow",
  "Action": [
    "route53resolver:*"
  ],
  "Resource": "*"
}
```

**其他必需权限**：
```json
{
  "Effect": "Allow",
  "Action": [
    "ram:*",
    "ec2:DescribeVpcs",
    "ec2:DescribeSubnets",
    "ec2:DescribeRouteTables",
    "iam:CreateServiceLinkedRole",
    "iam:ListRoles",
    "iam:GetRole",
    "config:DescribeConfigurationRecorders"
  ],
  "Resource": "*"
}
```

#### 为什么需要根账号管理员
1. **Organizations 管理权限**：只有根账号可以管理组织级策略
2. **跨服务协调权限**：需要在多个 AWS 服务间建立信任关系
3. **安全策略执行权限**：SCP 策略只能由根账号创建和应用

### ⚠️ 根账号的其他用户
**可能支持，但需要额外配置**

#### 必需的 IAM 策略
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "organizations:DescribeOrganization",
        "organizations:ListRoots",
        "organizations:ListPolicies",
        "organizations:CreatePolicy",
        "organizations:AttachPolicy",
        "organizations:EnableAWSServiceAccess",
        "fms:GetAdminAccount",
        "fms:PutAdminAccount", 
        "fms:ListPolicies",
        "fms:PutPolicy",
        "fms:GetPolicy",
        "fms:GetComplianceDetail",
        "network-firewall:*",
        "route53resolver:*",
        "ram:*",
        "ec2:DescribeVpcs",
        "ec2:DescribeSubnets",
        "ec2:DescribeRouteTables",
        "iam:CreateServiceLinkedRole",
        "iam:GetRole",
        "iam:ListRoles",
        "config:DescribeConfigurationRecorders"
      ],
      "Resource": "*"
    }
  ]
}
```

#### 限制和风险
- 需要手动授予广泛权限
- 可能因权限不足导致部署失败
- 增加权限管理复杂性

### ❌ 成员账号管理员
**无法执行，缺少关键权限**

#### 缺少的关键权限
- 无法访问 AWS Organizations API
- 无法创建或管理 SCP 策略
- 无法设置 Firewall Manager 管理员账户
- 无法进行组织级资源共享设置

#### 架构限制
- AWS Organizations API 只能从根账号调用
- 成员账号无法直接访问组织级别的操作
- 这是 AWS 安全设计的核心，无法通过 IAM 策略绕过

## 权限验证

### 执行前权限检查脚本
```bash
chmod +x check-permissions.sh
./check-permissions.sh

# 检查指定的 AWS Profile 权限
AWS_PROFILE="poc" ./check-permissions.sh
```

## 最佳实践

### 🎯 推荐做法
1. **使用根账号管理员**
   - 权限完整，无需额外配置
   - 符合 AWS 安全最佳实践
   - 避免权限问题导致的部署失败

2. **执行前验证**
   - 运行权限检查脚本
   - 确认所有必需权限都已具备

3. **最小权限原则**
   - 部署完成后，可以创建专门的运维角色
   - 日常管理使用受限权限的角色

### ⚠️ 注意事项
1. **权限范围广泛**
   - 部署脚本需要多个 AWS 服务的完全权限
   - 建议在专门的管理环境中执行

2. **一次性操作**
   - 初始部署通常只需执行一次
   - 后续维护可以使用更受限的权限

3. **安全考虑**
   - 使用 MFA 保护根账号
   - 记录所有管理操作
   - 定期审查权限使用

## 故障排除

### 常见权限错误

#### 错误1：Organizations 权限不足
```
AccessDenied: User is not authorized to perform: organizations:DescribeOrganization
```
**解决方案**：确保使用根账号管理员或具有 Organizations 完全权限的用户

#### 错误2：Firewall Manager 权限不足
```
AccessDenied: User is not authorized to perform: fms:PutAdminAccount
```
**解决方案**：确保用户具有 Firewall Manager 管理权限

#### 错误3：跨服务权限不足
```
AccessDenied: Cannot create service-linked role
```
**解决方案**：确保用户具有 `iam:CreateServiceLinkedRole` 权限

### 权限问题诊断步骤
1. 运行权限检查脚本
2. 检查 AWS CLI 配置和凭证
3. 验证用户身份和权限
4. 查看 CloudTrail 日志了解具体权限错误

## 总结

| 用户类型 | 支持程度 | 推荐程度 | 备注 |
|---------|---------|---------|------|
| **根账号管理员** | ✅ 完全支持 | 🌟🌟🌟🌟🌟 | 推荐使用 |
| **根账号其他用户** | ⚠️ 需要配置 | 🌟🌟 | 需要额外权限配置 |
| **成员账号管理员** | ❌ 不支持 | 🚫 | 无法执行 |

**建议**：为确保部署成功，强烈推荐使用根账号管理员执行部署脚本。如需使用其他用户，请先运行权限验证脚本确认权限充足。
