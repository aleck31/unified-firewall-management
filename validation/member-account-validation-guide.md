# 成员账户防火墙策略验证指南

本文档面向**成员账户用户**，指导如何验证组织级防火墙策略是否在您的账户中正确生效。

## 📋 验证概览

需要验证的三个方面：
1. **Network Firewall 规则**：网络流量过滤是否生效
2. **DNS Firewall 规则**：恶意域名阻断是否生效  
3. **SCP 保护策略**：防火墙配置修改限制是否生效

---

## 🔥 Network Firewall 验证

### 1. 检查防火墙资源是否自动创建

```bash
# 检查您账户中的 Network Firewall
aws network-firewall list-firewalls --region ap-northeast-1

# 检查防火墙策略
aws network-firewall list-firewall-policies --region ap-northeast-1

# 检查规则组（应该看到共享的规则组）
aws network-firewall list-rule-groups --region ap-northeast-1
```

**预期结果**：
- ✅ 应该看到自动创建的防火墙实例
- ✅ 应该看到来自管理账户共享的规则组
- ✅ 防火墙应该关联到您的 VPC

### 2. 检查 VPC 中的防火墙端点

```bash
# 检查 VPC 端点
aws ec2 describe-vpc-endpoints --region ap-northeast-1 \
  --filters "Name=service-name,Values=com.amazonaws.vpce.ap-northeast-1.network-firewall"

# 检查子网关联
aws network-firewall describe-firewall --firewall-name <防火墙名称> --region ap-northeast-1
```

### 3. 测试网络流量过滤

**测试方法 1：检查路由表**
```bash
# 检查路由表是否指向防火墙端点
aws ec2 describe-route-tables --region ap-northeast-1 \
  --filters "Name=vpc-id,Values=<您的VPC-ID>"
```

**测试方法 2：实际流量测试**
```bash
# 在 EC2 实例中测试（如果有阻断规则）
# 例如：尝试访问被阻断的端口或协议
curl -m 10 http://example.com:8080  # 应该被阻断
ping 8.8.8.8  # 根据规则可能被允许或阻断
```

---

## 🌐 DNS Firewall 验证

### 1. 检查 DNS Firewall 配置

```bash
# 检查 DNS Firewall 规则组关联
aws route53resolver list-firewall-rule-group-associations --region ap-northeast-1

# 检查规则组详情
aws route53resolver list-firewall-rule-groups --region ap-northeast-1

# 检查域名列表
aws route53resolver list-firewall-domain-lists --region ap-northeast-1
```

**预期结果**：
- ✅ 应该看到来自管理账户的 DNS 规则组关联
- ✅ 规则组应该关联到您的 VPC

### 2. 测试 DNS 阻断功能

**方法 1：使用 nslookup 测试**
```bash
# 测试被阻断的域名（根据管理员配置）
nslookup badsite.org
nslookup example.com  # 如果在阻断列表中
nslookup www.wicar.org  # 测试域名

# 测试正常域名
nslookup google.com  # 应该正常解析
```

**方法 2：使用 dig 测试**
```bash
# 详细的 DNS 查询测试
dig badsite.org
dig @8.8.8.8 badsite.org  # 对比公共 DNS 结果
```

**预期结果**：
- ❌ 被阻断的域名应该返回 `NXDOMAIN` 或被重定向
- ✅ 正常域名应该正常解析

### 3. 检查 CloudWatch 日志

```bash
# 查看 DNS Firewall 日志（如果启用了日志记录）
aws logs describe-log-groups --region ap-northeast-1 \
  --log-group-name-prefix "/aws/route53resolver"

# 查看具体日志
aws logs filter-log-events --region ap-northeast-1 \
  --log-group-name "/aws/route53resolver/firewall" \
  --start-time $(date -d '1 hour ago' +%s)000
```

---

## 🛡️ SCP 保护策略验证

### 1. 测试防火墙配置修改限制

**测试 1：尝试删除防火墙**
```bash
# 这个命令应该被 SCP 阻止
aws network-firewall delete-firewall \
  --firewall-name <防火墙名称> \
  --region ap-northeast-1
```

**预期结果**：
```
An error occurred (AccessDenied) when calling the DeleteFirewall operation: 
User: arn:aws:iam::ACCOUNT:user/USERNAME is not authorized to perform: 
network-firewall:DeleteFirewall with an explicit deny
```

**测试 2：尝试修改防火墙策略**
```bash
# 这个命令应该被 SCP 阻止
aws network-firewall update-firewall-policy \
  --firewall-policy-name <策略名称> \
  --firewall-policy Description="Test modification" \
  --region ap-northeast-1
```

**测试 3：尝试删除 DNS 防火墙规则组**
```bash
# 这个命令应该被 SCP 阻止
aws route53resolver delete-firewall-rule-group \
  --firewall-rule-group-id <规则组ID> \
  --region ap-northeast-1
```

### 2. 验证允许的操作

**测试：查看操作应该被允许**
```bash
# 这些只读操作应该被允许
aws network-firewall list-firewalls --region ap-northeast-1
aws network-firewall describe-firewall --firewall-name <名称> --region ap-northeast-1
aws route53resolver list-firewall-rule-groups --region ap-northeast-1
```

---

## 📊 完整验证脚本

创建一个自动化验证脚本：

```bash
#!/bin/bash
# member-validation-test.sh

REGION="ap-northeast-1"
echo "=== 成员账户防火墙策略验证 ==="

# 1. Network Firewall 验证
echo "1. 检查 Network Firewall..."
FIREWALLS=$(aws network-firewall list-firewalls --region $REGION --query 'Firewalls[*].FirewallName' --output text)
if [ -n "$FIREWALLS" ]; then
    echo "✅ 发现防火墙: $FIREWALLS"
else
    echo "❌ 未发现防火墙实例"
fi

# 2. DNS Firewall 验证
echo "2. 检查 DNS Firewall..."
DNS_ASSOCIATIONS=$(aws route53resolver list-firewall-rule-group-associations --region $REGION --query 'FirewallRuleGroupAssociations[*].Id' --output text)
if [ -n "$DNS_ASSOCIATIONS" ]; then
    echo "✅ 发现 DNS 防火墙关联: $(echo $DNS_ASSOCIATIONS | wc -w) 个"
else
    echo "❌ 未发现 DNS 防火墙关联"
fi

# 3. SCP 限制验证
echo "3. 测试 SCP 限制..."
if [ -n "$FIREWALLS" ]; then
    FIRST_FIREWALL=$(echo $FIREWALLS | awk '{print $1}')
    echo "测试删除防火墙限制..."
    
    # 尝试删除防火墙（应该被拒绝）
    DELETE_RESULT=$(aws network-firewall delete-firewall --firewall-name "$FIRST_FIREWALL" --region $REGION 2>&1 || echo "DENIED")
    
    if echo "$DELETE_RESULT" | grep -q "AccessDenied\|not authorized\|explicit deny"; then
        echo "✅ SCP 保护生效：防火墙删除被阻止"
    else
        echo "❌ SCP 保护可能未生效"
    fi
fi

echo "=== 验证完成 ==="
```

---

## 🔍 故障排除

### 常见问题

**问题 1：看不到防火墙资源**
- **原因**：可能您的账户不在目标 OU 中，或者 AWS Config 未启用
- **解决**：联系管理员确认账户位置和 Config 状态

**问题 2：DNS 阻断不生效**
- **原因**：可能 VPC 的 DNS 解析器配置问题
- **解决**：检查 VPC 的 `enableDnsHostnames` 和 `enableDnsSupport` 设置

**问题 3：SCP 限制不生效**
- **原因**：可能您使用的是管理员角色或特殊权限角色
- **解决**：使用普通用户身份测试

### 获取帮助

如果验证过程中遇到问题：

1. **收集信息**：
   ```bash
   # 收集账户信息
   aws sts get-caller-identity
   aws organizations describe-account --account-id $(aws sts get-caller-identity --query Account --output text)
   ```

2. **联系管理员**：提供上述信息和具体错误消息

3. **查看 CloudTrail**：检查相关 API 调用日志

---

## 📋 验证检查清单

- [ ] Network Firewall 实例已自动创建
- [ ] 规则组已通过 RAM 共享到账户
- [ ] VPC 路由表指向防火墙端点
- [ ] DNS Firewall 规则组已关联到 VPC
- [ ] 恶意域名查询被正确阻断
- [ ] 正常域名查询工作正常
- [ ] 防火墙删除操作被 SCP 阻止
- [ ] 防火墙修改操作被 SCP 阻止
- [ ] 只读查看操作正常工作

**全部通过表示组织级防火墙策略在您的账户中正确生效！** ✅
