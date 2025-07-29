#!/bin/bash

# AWS 多账号防火墙管理方案权限检查脚本
# 用于验证当前用户是否具备执行部署脚本的必要权限

echo "=== AWS 多账号防火墙管理权限验证 ==="
echo "检查时间: $(date)"
echo "当前用户: $(aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null || echo '无法获取用户信息')"
echo ""

# 权限检查结果统计
PASSED=0
FAILED=0

# 检查函数
check_permission() {
    local service_name="$1"
    local command="$2"
    local description="$3"
    
    echo -n "检查 $service_name 权限..."
    if eval "$command" >/dev/null 2>&1; then
        echo " ✅ 通过"
        ((PASSED++))
    else
        echo " ❌ 失败 - $description"
        ((FAILED++))
    fi
}

# 1. 检查基础 STS 权限
check_permission "STS 身份验证" \
    "aws sts get-caller-identity" \
    "需要基础的 AWS 访问权限"

# 2. 检查 Organizations 基础权限
check_permission "Organizations 基础" \
    "aws organizations describe-organization" \
    "需要 organizations:DescribeOrganization 权限"

# 3. 检查 Organizations 管理权限
check_permission "Organizations 管理" \
    "aws organizations list-roots" \
    "需要 organizations:ListRoots 权限"

# 4. 检查 Organizations 策略权限
check_permission "Organizations 策略" \
    "aws organizations list-policies --filter SERVICE_CONTROL_POLICY" \
    "需要 organizations:ListPolicies 权限"

# 5. 检查 Firewall Manager 基础权限
check_permission "Firewall Manager 基础" \
    "aws fms get-admin-account" \
    "需要 fms:GetAdminAccount 权限（可能未设置管理员账户）"

# 6. 检查 Firewall Manager 策略权限
check_permission "Firewall Manager 策略" \
    "aws fms list-policies" \
    "需要 fms:ListPolicies 权限"

# 7. 检查 Network Firewall 权限
check_permission "Network Firewall" \
    "aws network-firewall list-rule-groups" \
    "需要 network-firewall:ListRuleGroups 权限"

# 8. 检查 Route53 Resolver 权限
check_permission "Route53 Resolver" \
    "aws route53resolver list-firewall-rule-groups" \
    "需要 route53resolver:ListFirewallRuleGroups 权限"

# 9. 检查 RAM 权限（可选，某些区域可能不可用）
echo -n "检查 Resource Access Manager 权限..."
if aws ram get-resource-shares >/dev/null 2>&1; then
    echo " ✅ 通过"
    ((PASSED++))
else
    echo " ⚠️  可选 - RAM 服务可能在当前区域不可用或需要先启用"
    echo "   注意：部署脚本会自动启用 RAM 组织共享"
    # 不计入失败，因为这是可选的
fi

# 10. 检查 IAM 服务角色权限
check_permission "IAM 服务角色" \
    "aws iam list-roles --path-prefix /aws-service-role/" \
    "需要 iam:ListRoles 权限"

# 11. 检查 EC2 VPC 权限（Firewall Manager 需要）
check_permission "EC2 VPC" \
    "aws ec2 describe-vpcs --max-items 1" \
    "需要 ec2:DescribeVpcs 权限"

# 12. 检查 Config 权限（某些 Firewall Manager 功能需要）
check_permission "AWS Config" \
    "aws configservice describe-configuration-recorders" \
    "需要 config:DescribeConfigurationRecorders 权限（可选）"

echo ""
echo "=== 权限检查结果 ==="
echo "✅ 通过: $PASSED 项"
echo "❌ 失败: $FAILED 项"
echo ""

# 给出建议
if [ $FAILED -eq 0 ]; then
    echo "🎉 权限检查全部通过！"
    echo "✅ 当前用户具备执行部署脚本的所有必要权限"
    echo "✅ 可以安全执行 ./deploy-firewall-manager.sh"
elif [ $FAILED -le 2 ]; then
    echo "⚠️  权限检查部分失败"
    echo "🔧 建议："
    echo "   1. 检查失败的权限是否为可选权限（如 AWS Config）"
    echo "   2. 如果是必需权限，请联系管理员授予相应权限"
    echo "   3. 可以尝试执行部署脚本，但可能会遇到权限错误"
else
    echo "❌ 权限检查失败较多"
    echo "🚫 当前用户权限不足，无法执行部署脚本"
    echo "🔧 建议："
    echo "   1. 使用根账号管理员执行（推荐）"
    echo "   2. 或联系管理员授予必要权限"
    echo "   3. 参考 execution-permissions-guide.md 了解详细权限要求"
fi

echo ""
echo "📚 更多信息请参考: execution-permissions-guide.md"
echo "=== 权限检查完成 ==="
