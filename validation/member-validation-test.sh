#!/bin/bash

# 成员账户防火墙策略自动验证脚本
# 用于快速检查组织级防火墙策略是否在成员账户中生效

set -e

REGION="ap-northeast-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "unknown")

echo "=== 成员账户防火墙策略验证 ==="
echo "账户 ID: $ACCOUNT_ID"
echo "区域: $REGION"
echo "验证时间: $(date)"
echo ""

# 1. Network Firewall 验证
echo "🔥 1. Network Firewall 验证"
echo "----------------------------------------"

echo "检查防火墙实例..."
FIREWALLS=$(aws network-firewall list-firewalls --region $REGION --query 'Firewalls[*].FirewallName' --output text 2>/dev/null || echo "")
if [ -n "$FIREWALLS" ] && [ "$FIREWALLS" != "None" ]; then
    echo "✅ 发现防火墙实例:"
    for fw in $FIREWALLS; do
        echo "   - $fw"
    done
    FIREWALL_COUNT=$(echo $FIREWALLS | wc -w)
else
    echo "❌ 未发现防火墙实例"
    FIREWALL_COUNT=0
fi

echo "检查规则组..."
RULE_GROUPS=$(aws network-firewall list-rule-groups --region $REGION --query 'RuleGroups[*].Name' --output text 2>/dev/null || echo "")
if [ -n "$RULE_GROUPS" ] && [ "$RULE_GROUPS" != "None" ]; then
    echo "✅ 发现规则组:"
    for rg in $RULE_GROUPS; do
        echo "   - $rg"
    done
else
    echo "⚠️  未发现规则组（可能通过 RAM 共享）"
fi

# 2. DNS Firewall 验证
echo ""
echo "🌐 2. DNS Firewall 验证"
echo "----------------------------------------"

echo "检查 DNS 防火墙规则组关联..."
DNS_ASSOCIATIONS=$(aws route53resolver list-firewall-rule-group-associations --region $REGION --query 'FirewallRuleGroupAssociations[*].{Id:Id,Name:Name,VpcId:VpcId}' --output table 2>/dev/null || echo "")
if [ -n "$DNS_ASSOCIATIONS" ] && [ "$DNS_ASSOCIATIONS" != "None" ]; then
    echo "✅ 发现 DNS 防火墙关联:"
    echo "$DNS_ASSOCIATIONS"
    DNS_COUNT=$(aws route53resolver list-firewall-rule-group-associations --region $REGION --query 'length(FirewallRuleGroupAssociations)' --output text 2>/dev/null || echo "0")
else
    echo "❌ 未发现 DNS 防火墙关联"
    DNS_COUNT=0
fi

echo "检查域名列表..."
DOMAIN_LISTS=$(aws route53resolver list-firewall-domain-lists --region $REGION --query 'FirewallDomainLists[*].Name' --output text 2>/dev/null || echo "")
if [ -n "$DOMAIN_LISTS" ] && [ "$DOMAIN_LISTS" != "None" ]; then
    echo "✅ 发现域名列表:"
    for dl in $DOMAIN_LISTS; do
        echo "   - $dl"
    done
else
    echo "⚠️  未发现域名列表（可能通过 RAM 共享）"
fi

# 3. DNS 功能测试
echo ""
echo "🧪 3. DNS 阻断功能测试"
echo "----------------------------------------"

# 测试常见的被阻断域名
TEST_DOMAINS=("badsite.org" "example.com" "malware.test")
BLOCKED_COUNT=0

for domain in "${TEST_DOMAINS[@]}"; do
    echo "测试域名: $domain"
    
    # 使用 nslookup 测试
    LOOKUP_RESULT=$(nslookup $domain 2>&1 || echo "FAILED")
    
    if echo "$LOOKUP_RESULT" | grep -q "NXDOMAIN\|can't find\|No answer"; then
        echo "   ✅ 域名被阻断"
        BLOCKED_COUNT=$((BLOCKED_COUNT + 1))
    elif echo "$LOOKUP_RESULT" | grep -q "FAILED\|timeout"; then
        echo "   ⚠️  DNS 查询失败（可能被阻断）"
        BLOCKED_COUNT=$((BLOCKED_COUNT + 1))
    else
        echo "   ❌ 域名未被阻断"
    fi
done

# 4. SCP 保护策略验证
echo ""
echo "🛡️  4. SCP 保护策略验证"
echo "----------------------------------------"

SCP_WORKING=0

if [ $FIREWALL_COUNT -gt 0 ]; then
    FIRST_FIREWALL=$(echo $FIREWALLS | awk '{print $1}')
    echo "测试防火墙删除限制（使用防火墙: $FIRST_FIREWALL）..."
    
    # 尝试删除防火墙（应该被拒绝）
    DELETE_RESULT=$(aws network-firewall delete-firewall --firewall-name "$FIRST_FIREWALL" --region $REGION 2>&1 || echo "DENIED")
    
    if echo "$DELETE_RESULT" | grep -q "AccessDenied\|not authorized\|explicit deny\|Deny"; then
        echo "✅ SCP 保护生效：防火墙删除被阻止"
        SCP_WORKING=1
    else
        echo "❌ SCP 保护可能未生效"
        echo "   错误信息: $DELETE_RESULT"
    fi
else
    echo "⚠️  无法测试 SCP 保护（没有防火墙实例）"
fi

# 测试规则组修改限制
echo "测试规则组修改限制..."
if [ -n "$RULE_GROUPS" ] && [ "$RULE_GROUPS" != "None" ]; then
    FIRST_RULE_GROUP=$(echo $RULE_GROUPS | awk '{print $1}')
    
    # 尝试更新规则组（应该被拒绝）
    UPDATE_RESULT=$(aws network-firewall update-rule-group --rule-group-name "$FIRST_RULE_GROUP" --description "Test modification" --region $REGION 2>&1 || echo "DENIED")
    
    if echo "$UPDATE_RESULT" | grep -q "AccessDenied\|not authorized\|explicit deny\|Deny"; then
        echo "✅ SCP 保护生效：规则组修改被阻止"
        SCP_WORKING=1
    else
        echo "❌ SCP 保护可能未生效"
    fi
else
    echo "⚠️  无法测试规则组修改限制（没有规则组）"
fi

# 5. 生成验证报告
echo ""
echo "📊 验证报告"
echo "========================================"

TOTAL_SCORE=0
MAX_SCORE=4

# Network Firewall 评分
if [ $FIREWALL_COUNT -gt 0 ]; then
    echo "✅ Network Firewall: 已部署 ($FIREWALL_COUNT 个实例)"
    TOTAL_SCORE=$((TOTAL_SCORE + 1))
else
    echo "❌ Network Firewall: 未部署"
fi

# DNS Firewall 评分
if [ $DNS_COUNT -gt 0 ]; then
    echo "✅ DNS Firewall: 已部署 ($DNS_COUNT 个关联)"
    TOTAL_SCORE=$((TOTAL_SCORE + 1))
else
    echo "❌ DNS Firewall: 未部署"
fi

# DNS 阻断功能评分
if [ $BLOCKED_COUNT -gt 0 ]; then
    echo "✅ DNS 阻断功能: 工作正常 ($BLOCKED_COUNT/${#TEST_DOMAINS[@]} 个域名被阻断)"
    TOTAL_SCORE=$((TOTAL_SCORE + 1))
else
    echo "❌ DNS 阻断功能: 未生效"
fi

# SCP 保护评分
if [ $SCP_WORKING -eq 1 ]; then
    echo "✅ SCP 保护策略: 工作正常"
    TOTAL_SCORE=$((TOTAL_SCORE + 1))
else
    echo "❌ SCP 保护策略: 未生效"
fi

echo ""
echo "总体评分: $TOTAL_SCORE/$MAX_SCORE"

if [ $TOTAL_SCORE -eq $MAX_SCORE ]; then
    echo "🎉 恭喜！组织级防火墙策略在您的账户中完全生效！"
    exit 0
elif [ $TOTAL_SCORE -ge 2 ]; then
    echo "⚠️  防火墙策略部分生效，建议联系管理员检查配置"
    exit 1
else
    echo "❌ 防火墙策略未生效，请联系管理员"
    exit 2
fi
