# Travel Agency Itinerary Import Pipeline

這條管線的目標不是直接爬網站後立刻丟進模型，而是把外部行程先變成「可檢查、可校正、可回放」的訓練樣本。

## 1. 整體流程

建議流程：

1. 先從旅行社網頁抽出每日行程文字
2. 整理成 `backend/data/agency_itineraries_raw.json`
3. 執行：

```bash
python3 backend/scripts/import_agency_itineraries.py
```

4. 產生：
   - `backend/data/historical_itineraries.imported.json`
   - `backend/data/agency_itinerary_match_report.json`
5. 檢查未匹配景點
6. 必要時補資料庫景點或手動修正名稱
7. 確認後再把 sample 合併進 `backend/data/historical_itineraries.json`
8. 最後再跑：

```bash
python3 backend/scripts/train_itinerary_ranker.py
```

## 2. 原始輸入格式

請先參考：

- [`agency_itineraries_raw.example.json`](/Users/kevinicnine/Desktop/smart_travel/backend/data/agency_itineraries_raw.example.json)

每筆 source 建議至少有：

- `id`
- `title`
- `url`
- `context`
- `days[].items[]`

每個 item 建議欄位：

- `name`
- `arrivalTime`
- `departureTime`
- `type`
- `city`
- `notes`

常見 type：

- `place`
- `meal`
- `hotel`
- `departure`
- `arrival`
- `note`

## 3. 匯入腳本做了什麼

[`import_agency_itineraries.py`](/Users/kevinicnine/Desktop/smart_travel/backend/scripts/import_agency_itineraries.py) 會：

- 跳過 `departure / arrival / hotel / note`
- 只保留可學習的景點型 item
- 根據景點名稱去 [`db.json`](/Users/kevinicnine/Desktop/smart_travel/backend/data/db.json) 做名稱對應
- 自動補：
  - `stayMinutes`
  - `slot`
  - `transitMinutesFromPrevious`
- 輸出成 `historical_itineraries` 可吃的 sample

目前匹配策略是：

1. 正規化後精準比對
2. 包含關係比對
3. 字串相似度比對

如果最高分太低，該景點會進未匹配報表，不會硬塞進訓練樣本。

## 4. 匯入輸出

### historical_itineraries.imported.json

這是可直接合併進訓練資料的 sample 格式。

### agency_itinerary_match_report.json

這是人工校正用報表，會列出：

- 哪些景點成功對應
- 哪些景點沒對到
- 每個未匹配景點的候選 placeId
- 哪些 item 被略過，以及原因

## 5. 建議工作方式

不要一次對很多網站做全自動抓取。比較穩的做法是：

- 先針對單一旅行社做 parser adapter
- 抽出原始資料後先人工看一輪
- 再執行正規化與 placeId 對應
- 對不到的景點再補資料庫

這樣模型吃到的資料品質才不會太差。

## 6. 目前限制

這版腳本還沒有直接爬網站。它只處理「已經整理好的原始 JSON」。

原因是：

- 每家旅行社 HTML 結構不同
- 景點命名差異很大
- 很多網站還會混住宿、早餐、自理、備註、司機接送等文字

先把「網站抓取」和「訓練樣本正規化」拆開，維護成本會低很多。

## 7. 下一步可擴充

之後可以再加：

- 指定網站的 scraper adapter
- 後台貼 URL 後自動生成 raw JSON 草稿
- 未匹配景點人工指派 placeId 的後台頁
- 匯入後直接追加到 `historical_itineraries.json`
