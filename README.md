
# AWS 多账号防火墙统一管理方案

## 方案概述
通过 **AWS Firewall Manager + SCP** 实现多账号 Network Firewall 和 DNS Firewall 的统一管理和保护，防止子账号擅自修改防火墙配置。

## 快速开始

### 前提条件
- 已启用 AWS Organizations
- 使用**根账号的 admin 用户**执行（推荐）
- 具备必要的 IAM 权限

> 📋 **权限要求**：详细的执行权限说明请参考 `execution-permissions-guide.md`

### 1. 权限检查（推荐）
```bash
# 执行权限检查脚本
./check-permissions.sh
```

### 2. 配置参数
编辑部署脚本，修改以下参数：

```bash
# 配置变量 - 请根据实际环境修改
REGION="ap-northeast-1"               # 替换为你的区域
```

> 📝 **注意**：脚本会自动获取账户ID和根OU ID，无需手动配置

### 3. 分步部署脚本

```bash
# 步骤0：检查和配置前置条件
chmod +x deploy-0-prerequisites.sh
./deploy-0-prerequisites.sh

# 步骤1：部署 Firewall Manager
chmod +x deploy-1-firewall-manager.sh
./deploy-1-firewall-manager.sh

# 步骤2：部署 SCP 保护策略
chmod +x deploy-2-scp-protect.sh
./deploy-2-scp-protect.sh
```

### 4. 验证部署
- 检查 [Firewall Manager 控制台](https://console.aws.amazon.com/wafv2/fms)
- 验证策略状态为 "ACTIVE"
- 测试成员账户无法修改防火墙配置

## 实现效果

| 角色 | 权限 |
|------|------|
| **子账号用户** | ❌ 无法修改防火墙配置（被 SCP 阻止） |
| **Firewall Manager** | ✅ 可以正常管理和更新策略 |
| **根账号 admin** | ✅ 保留完全控制权限 |

## 核心优势
- 🎯 **统一管理** - 一次配置，全组织应用
- 🛡️ **实时保护** - SCP 实时阻止未授权修改  
- 🤖 **自动化** - 新账户和资源自动应用策略
- 📊 **持续合规** - 自动监控和修复

## 文档结构
- `firewall-manager-deployment-guide.md` - 完整实施指南
- `deploy-1-firewall-manager.sh` - 部署 Firewall Manager
- `deploy-2-scp-protect.sh` - 部署 SCP 保护策略
- `execution-permissions-guide.md` - 执行权限需求说明
- `check-permissions.sh` - 权限检查脚本
- `firewall-protection-scp.json` - SCP 策略文件
- `firewall-manager-configs/` - Firewall Manager 策略配置

## 支持
如遇问题，请参考 `firewall-manager-deployment-guide.md` 中的故障排除章节。
