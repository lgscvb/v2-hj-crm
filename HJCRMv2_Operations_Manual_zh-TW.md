# Hour Jungle CRM v2 操作文件（維運用）

版本：v2
更新日期：2026-01-02

這份文件用最簡單的方式，告訴你怎麼讓系統「好好跑」。

---

## 1. 這是什麼
這是一套管理「客戶、合約、繳費、發票、續約」的系統。

---

## 2. 重要網址
- 前端（給人用）：https://hj-v2.yourspce.org
- 後端 API：https://api-v2.yourspce.org
- 不要用：https://hj-v2.pages.dev（可能有舊快取）

---

## 3. 需要的帳號
- GitHub：推程式碼
- GCP：進 VM
- Cloudflare：前端自動部署設定

---

## 4. 每天檢查（5 分鐘）
1. 打開前端網站，能正常登入。
2. 打開「合約 / 繳費 / 發票 / 續約」頁面，看資料有出現。
3. 如果看不到資料，先記下時間、頁面、錯誤訊息。

---

## 5. 部署（最常用）
### 後端
```bash
# 在專案根目錄
make deploy-backend
```

### 前端
只要 push 到 main，就會自動部署。
```bash
git add . && git commit -m "feat: 說明" && git push
```

---

## 6. 重啟後端（網站壞掉時）
```bash
# 進 VM
gcloud compute ssh hj-crm-vm --zone=us-west1-a --project=hj-crm-482012

# 在 VM 裡
cd ~/v2-hj-crm/backend
docker-compose restart mcp-server
```

如果還是壞掉，再重啟全部：
```bash
docker-compose down
docker-compose up -d
```

---

## 7. 查看 Log（除錯用）
```bash
# 進 VM 後

# 看最近 100 行
docker logs --tail 100 hj-mcp-server

# 持續追蹤（Ctrl+C 停止）
docker logs -f hj-mcp-server
```

---

## 8. 資料庫 Migration（需要改資料結構時）
1. 在 `backend/sql/migrations/` 新增 SQL 檔案。
2. 到 VM 執行 SQL。

```bash
# 進 VM
gcloud compute ssh hj-crm-vm --zone=us-west1-a --project=hj-crm-482012

# 在 VM 裡執行 migration（把 XXX 換成實際檔名）
docker exec -i hj-postgres psql -U hjadmin -d hourjungle < ~/v2-hj-crm/backend/sql/migrations/XXX_migration_name.sql

# 重新載入 schema（讓 API 看到新欄位）
docker exec hj-postgres psql -U hjadmin -d hourjungle -c "NOTIFY pgrst, 'reload schema';"
```

> 提醒：若 VM 的帳號/DB 名稱不同，以 `.env` 為準。

---

## 9. 備份（重大改動前）
如果不確定備份方式，先問技術同事。

常見做法（示意）：
```bash
# 在 VM 裡
docker exec -i hj-postgres pg_dump -U hjadmin -d hourjungle > /tmp/hj_backup_$(date +%Y%m%d).sql
```

---

## 10. 常見問題（很簡單的判斷）

| 問題 | 第一步 |
|------|--------|
| 前端打不開 | 確認網址是否正確（不要用 pages.dev） |
| API 出錯 | 先重啟 mcp-server |
| 資料欄位怪怪的 | 檢查最新 migration 是否已部署 |
| 不確定哪裡壞了 | 看 Log（第 7 節） |

---

## 11. 交付檢查清單（每次上線前）
- [ ] 前端能打開並登入
- [ ] 合約/繳費/發票/續約頁能顯示資料
- [ ] 最新 migration 已執行
- [ ] 重大改動有備份
