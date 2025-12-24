# Hour Jungle CRM v2 - Makefile
# 常用指令集合

.PHONY: help security security-fix update-deps deploy-backend deploy-all

help:
	@echo "Hour Jungle CRM v2 - 可用指令"
	@echo ""
	@echo "安全相關:"
	@echo "  make security       - 執行安全掃描（前端 + 後端）"
	@echo "  make security-fix   - 自動修復安全漏洞"
	@echo "  make update-deps    - 更新所有依賴"
	@echo ""
	@echo "部署相關:"
	@echo "  make deploy-backend - 部署後端到 GCP VM"
	@echo "  make deploy-all     - 部署前後端"
	@echo ""
	@echo "開發相關:"
	@echo "  make dev-frontend   - 啟動前端開發伺服器"
	@echo "  make dev-backend    - 啟動後端（Docker）"

# === 安全掃描 ===

security:
	@echo "=== 前端安全掃描 ==="
	cd frontend && npm audit
	@echo ""
	@echo "=== 後端安全掃描 ==="
	cd backend && ./scripts/security-check.sh

security-fix:
	@echo "=== 修復前端漏洞 ==="
	cd frontend && npm audit fix --force || true
	@echo ""
	@echo "=== 後端漏洞需手動處理 ==="
	@echo "請執行: pip-audit -r backend/mcp-server/requirements.txt --fix"

update-deps:
	@echo "=== 更新前端依賴 ==="
	cd frontend && npm update && npm audit fix
	@echo ""
	@echo "=== 更新後端依賴 ==="
	cd backend/mcp-server && pip install --upgrade -r requirements.txt

# === 部署 ===

deploy-backend:
	@echo "=== 部署後端到 GCP VM ==="
	git add . && git commit -m "chore: deploy" --allow-empty && git push
	gcloud compute ssh hj-crm-vm --zone=us-west1-a --project=hj-crm-482012 \
		--command="cd ~/v2-hj-crm && git pull && cd backend && docker-compose down && docker-compose up -d"

deploy-all: deploy-backend
	@echo ""
	@echo "=== 前端會自動部署到 Cloudflare Pages ==="
	@echo "請檢查: https://hj-v2.pages.dev"

# === 開發 ===

dev-frontend:
	cd frontend && npm run dev

dev-backend:
	cd backend && docker-compose up -d
