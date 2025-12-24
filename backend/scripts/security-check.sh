#!/bin/bash
# 後端安全掃描腳本
# 用法：./scripts/security-check.sh

set -e

echo "================================"
echo " Hour Jungle CRM - Security Scan"
echo "================================"
echo ""

# 顏色定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 切換到腳本目錄
cd "$(dirname "$0")/.."

# 檢查 pip-audit 是否安裝
if ! command -v pip-audit &> /dev/null; then
    echo -e "${YELLOW}Installing pip-audit...${NC}"
    pip install pip-audit
fi

# 檢查 Python 依賴漏洞
echo ""
echo "=== Python Dependencies Audit ==="
echo ""

cd mcp-server

if pip-audit -r requirements.txt --format json > /tmp/pip-audit-report.json 2>&1; then
    echo -e "${GREEN}✓ No vulnerabilities found in Python dependencies${NC}"
else
    VULN_COUNT=$(cat /tmp/pip-audit-report.json | python3 -c "import sys, json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
    if [ "$VULN_COUNT" -gt 0 ]; then
        echo -e "${RED}✗ Found $VULN_COUNT vulnerabilities:${NC}"
        pip-audit -r requirements.txt
        echo ""
        echo -e "${YELLOW}Run 'pip-audit -r requirements.txt --fix' to auto-fix${NC}"
    fi
fi

cd ..

# 檢查 Docker 基礎映像
echo ""
echo "=== Docker Base Image Check ==="
echo ""

if command -v docker &> /dev/null; then
    # 檢查 Python 映像版本
    PYTHON_IMAGE=$(grep "FROM python" mcp-server/Dockerfile 2>/dev/null | head -1 || echo "")
    if [ -n "$PYTHON_IMAGE" ]; then
        echo "Current Python image: $PYTHON_IMAGE"

        # 檢查最新版本
        echo -e "${YELLOW}Tip: Check https://hub.docker.com/_/python for latest stable version${NC}"
    fi

    # 檢查 PostgreSQL 映像版本
    POSTGRES_IMAGE=$(grep "image: postgres" docker-compose.yml 2>/dev/null || echo "")
    if [ -n "$POSTGRES_IMAGE" ]; then
        echo "Current PostgreSQL image: $POSTGRES_IMAGE"
        echo -e "${YELLOW}Tip: Check https://hub.docker.com/_/postgres for latest stable version${NC}"
    fi
else
    echo -e "${YELLOW}Docker not installed, skipping Docker image check${NC}"
fi

# 檢查 PostgreSQL 版本（如果運行中）
echo ""
echo "=== PostgreSQL Version Check ==="
echo ""

if command -v docker &> /dev/null; then
    if docker ps --format '{{.Names}}' | grep -q "hj-postgres"; then
        PG_VERSION=$(docker exec hj-postgres psql -U hjadmin -d hourjungle -t -c "SELECT version();" 2>/dev/null | head -1 || echo "Unable to get version")
        echo "Running PostgreSQL: $PG_VERSION"

        # 檢查是否有安全更新
        echo -e "${YELLOW}Tip: Check https://www.postgresql.org/support/security/ for security advisories${NC}"
    else
        echo "PostgreSQL container is not running"
    fi
else
    echo "Docker not available"
fi

echo ""
echo "================================"
echo " Security Scan Complete"
echo "================================"
