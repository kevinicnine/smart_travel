# Itinerary Learning Pipeline

這條路線不是直接訓練生成式模型，而是先用歷史行程學出「景點排序偏好」，再回灌到現有的 rule-based 排程核心。

## 1. 歷史資料格式

歷史行程資料預設放在：

- `backend/data/historical_itineraries.json`

可先參考：

- [`historical_itineraries.example.json`](/Users/kevinicnine/Desktop/smart_travel/backend/data/historical_itineraries.example.json)

每筆 sample 至少要有：

- `context.interests`
- `context.tripPurpose`
- `context.travelBehavior`
- `context.targetPrice`
- `days[].items[].placeId`

`placeId` 必須能對應到 [`db.json`](/Users/kevinicnine/Desktop/smart_travel/backend/data/db.json) 裡的景點 id，不然訓練時會被跳過。

如果資料來源是旅行社、部落格或其他外部行程，建議先走旅行社匯入管線，再轉成訓練樣本：

- [`agency_itinerary_import.md`](/Users/kevinicnine/Desktop/smart_travel/backend/docs/agency_itinerary_import.md)

## 2. 訓練腳本

執行：

```bash
python3 backend/scripts/train_itinerary_ranker.py
```

可選環境變數：

```bash
HISTORICAL_ITINERARIES_PATH=backend/data/historical_itineraries.json
PLACES_DB_PATH=backend/data/db.json
OUTPUT_PATH=backend/data/itinerary_ranker_weights.json
```

輸出檔：

- `backend/data/itinerary_ranker_weights.json`

## 3. 模型輸出內容

這不是黑盒模型，而是可讀的偏好權重：

- `globalTagWeights`
- `interestTagWeights`
- `tripPurposeTagWeights`
- `travelBehaviorTagWeights`
- `priceAffinity`

它們代表：

- 哪些 tag 在歷史行程中常被選
- 在特定興趣下，哪些 tag 更常出現
- 在不同旅遊目的、旅伴型態、價格條件下，哪些景點特徵更容易被選入

## 4. 線上整合方式

後端啟動時會嘗試讀取：

- `backend/data/itinerary_ranker_weights.json`

如果檔案存在，行程打分函式 `_scorePlace(...)` 會額外加上一層學習式分數。

如果檔案不存在或讀取失敗：

- 系統維持原本 rule-based 邏輯
- 不會影響現有行程功能

## 5. 建議資料品質

如果要讓學習結果有意義，建議樣本至少做到：

- 同一種旅遊目的各收集 20 筆以上
- placeId 使用真實資料庫景點 id
- 行程天數、目的、旅伴型態欄位盡量齊全
- 避免把明顯品質差或隨機亂排的行程混進高品質樣本

## 6. 下一步可擴充

之後可以再補：

- 使用者滿意度 / 星等作為 sample 權重
- pairwise ranking 訓練資料產生器
- 匯入別人行程的後台入口
- 訓練後自動刷新 Render 上的權重檔
