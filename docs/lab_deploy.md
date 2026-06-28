# Smart Travel 實驗室主機部署

這套配置把目前 Render 上的 3 個角色搬到實驗室主機：

- `backend`: Dart API
- `reminder-cron`: 每 5 分鐘掃一次提醒推播
- `web`: Nginx，負責提供 Flutter Web 與反向代理 `/api`、`/admin`

## 1. 主機需求

- Linux 主機
- 已安裝 Docker 與 Docker Compose Plugin
- 可 SSH 登入
- 若要使用 LINE webhook，主機必須有公開 `HTTPS` 網址

## 2. 上傳專案

在本機執行：

```bash
scp -r smart_travel your_user@your_host:/home/your_user/
```

登入主機：

```bash
ssh your_user@your_host
cd /home/your_user/smart_travel
```

## 3. 建立正式環境檔

```bash
cp backend/.env.production.example backend/.env.production
nano backend/.env.production
```

至少先填這幾個：

- `ADMIN_USERNAME`
- `ADMIN_PASSWORD`
- `ADMIN_TOKEN`
- `GOOGLE_MAPS_API_KEY`
- `GOOGLE_PLACES_SERVER_API_KEY`
- `REMINDER_CRON_TOKEN`

如果暫時不接資料庫，可以把 `DB_*` 全部留空，系統會改用 `deploy/data/db.json`。

## 4. 建 Flutter Web

這一步建議在你自己的電腦做，再把產物傳到主機。

```bash
cd /Users/kevinicnine/Desktop/smart_travel
flutter build web --release \
  --dart-define=SMART_TRAVEL_API_BASE=https://your-domain-or-ip \
  --dart-define=GOOGLE_MAPS_API_KEY=your-frontend-google-key
```

把輸出的前端檔案同步到主機：

```bash
rsync -av --delete build/web/ your_user@your_host:/home/your_user/smart_travel/deploy/frontend/
```

如果你暫時只有 IP、沒有 HTTPS，也可以先把 `SMART_TRAVEL_API_BASE` 改成 `http://your-ip` 做展示版；
但 LINE webhook 與正式環境仍建議使用 HTTPS。

## 5. 啟動服務

在主機上：

```bash
cd /home/your_user/smart_travel
docker compose -f docker-compose.lab.yml up -d --build
```

查看狀態：

```bash
docker compose -f docker-compose.lab.yml ps
```

查看後端 log：

```bash
docker compose -f docker-compose.lab.yml logs -f backend
```

查看提醒排程 log：

```bash
docker compose -f docker-compose.lab.yml logs -f reminder-cron
```

## 6. 驗證

- 首頁：`http://your-ip/`
- 健康檢查：`http://your-ip/health`
- 管理頁：`http://your-ip/admin`

提醒排程不是靠主機 `crontab`，而是 `reminder-cron` container 常駐執行，每 `300` 秒跑一次 `run_reminder_cron.py`。

## 7. 更新流程

程式碼更新後：

```bash
cd /home/your_user/smart_travel
docker compose -f docker-compose.lab.yml up -d --build
```

如果前端有改，重新執行 Flutter Web build，然後再同步一次 `build/web/` 到 `deploy/frontend/`。

## 8. LINE webhook 遷移

若你要保留 LINE 綁定與推播：

1. 在 `.env.production` 設定 `LINE_CHANNEL_ACCESS_TOKEN` 與 `LINE_CHANNEL_SECRET`
2. 到 LINE Developers 後台把 webhook URL 改成：

```text
https://your-domain/api/line/webhook
```

3. 確認主機可從外網連入，且有有效 HTTPS 憑證

若沒有 HTTPS，LINE webhook 通常不會通過。
