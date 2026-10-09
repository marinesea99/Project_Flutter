# 前端 API 串接與欄位紀錄

這份文件對照目前的 [Flutter 主程式](../lib/main.dart) 與 [Python 後端](https://github.com/marinesea99/Project_backend/blob/main/main.py) 整理，方便之後修改畫面或 API 時查找欄位。以下描述的是目前程式碼的處理方式，並非正式環境的連線測試報告。

## 資料怎麼進來

目前 Flutter Web 的資料流程分兩步：

1. 前端向 Binance 公開 API `GET https://data-api.binance.vision/api/v3/klines` 取得六種幣別的 1 小時 K 線。
2. 前端把原始 K 線傳給 Python 後端，由後端建立特徵、執行模型推論，再回傳儀表板需要的資料。

| 幣別 | Binance 交易對 | 每次請求筆數（limit） |
| --- | --- | ---: |
| USDC | `USDCUSDT` | 100 |
| TUSD | `TUSDUSDT` | 100 |
| BTC | `BTCUSDT` | 300 |
| ETH | `ETHUSDT` | 300 |
| SOL | `SOLUSDT` | 300 |
| XRP | `XRPUSDT` | 300 |

- Binance 單次 HTTP 逾時設定：**25 秒**。
- 後端推論請求逾時設定：**180 秒**。
- 前端預設後端主機：`https://quantproject-backend.onrender.com`。
- 可以在編譯／啟動時透過 `--dart-define=API_BASE_URL=https://YOUR_BACKEND_HOST` 覆蓋主機網址。

## 前端實際呼叫的 API

```http
POST /api/v1/dashboard/overview/from-klines
Accept: application/json
Content-Type: application/json
```

Request body 的根欄位為 `klines`，其中必須包含上述六組交易對，不能缺少或多出其他名稱。每組值是 Binance 原始 K 線的二維陣列；一根 K 線以依序排列的 12 個欄位表示（起始時間、OHLC、成交量及其他交易資訊），不是已轉成 `open`、`close` 等鍵值的物件。

單根 K 線的格式示意（實際請求要有六組交易對及足夠的歷史 K 線）：

```json
{
  "klines": {
    "USDCUSDT": [
      [1697040000000, "1.0000", "1.0001", "0.9999", "1.0000", "1000", 1697043599999, "1000", 100, "500", "500", "0"]
    ]
  }
}
```

這是**格式示意，不是可以直接拿來執行模型的完整請求**。

後端另保留 `GET /api/v1/dashboard/overview`，可由後端自行取得行情；但目前 `lib/main.dart` 使用的是上述 POST 路徑。健康檢查為 `GET /health`。

## 回傳資料

成功時，回傳物件的主要結構：

```text
success: true
timestamp: ...
data:
  stablecoins: { ... }
  cryptos: [ ... ]
```

前端要求 `success` 為 `true`，並要求 `data.stablecoins` 是物件、`data.cryptos` 是陣列。不再支援直接以根節點放置 `stablecoins`、`cryptos` 的舊格式。

### 加密貨幣：`data.cryptos`

每個陣列項目代表 BTC、ETH、SOL 或 XRP：

| 欄位 | 目前用途 |
| --- | --- |
| `coin` | 幣種代稱 |
| `current_price` | 目前價格 |
| `prediction_horizon_hours` | 後端目前提供 4 小時 |
| `up_score` | 模型方向分數，後端轉為 0–100 |
| `trend_label` | 偏多／偏空 |
| `display_threshold` | 0–100 的判斷門檻 |
| `threshold_gap` | 分數與門檻的差，單位為百分點 |
| `model_data_until` | 模型採用資料的截至時間 |
| `kline_interval` | K 線週期，目前為 `1h` |
| `kline_data` | OHLCV K 線陣列 |
| `model_info` | 模型名稱、預測目標、輸入筆數、特徵數量、門檻與訓練資訊 |

目前 `model_info` 中含 `model_name`、`prediction_target`、`target_definition`、`prediction_horizon_hours`、`input_kline_count`、`feature_count`、`display_threshold`、`validation_roc_auc` 和 `training_coverage` 等欄位。

`up_score` 是模型輸出的方向分數，**不能當成實際上漲機率**。

### 穩定幣：`data.stablecoins`

穩定幣部分沒有用 `cryptos` 的陣列格式，而是以 `usdc`／`tusd` 與模型名稱組成欄位前綴：

| 模型代稱 | 說明 |
| --- | --- |
| `xgboost` | XGBoost |
| `transformer_099` | Transformer 0.99 |
| `transformer_0995` | Transformer 0.995 |
| `ensemble` | XGBoost 與 Transformer 組合輸出 |

例如 `usdc_xgboost`，後端回傳的欄位為：

- `usdc_xgboost_current_price`
- `usdc_xgboost_future_6h_low`
- `usdc_xgboost_price_diff`
- `usdc_xgboost_depeg_probability`
- `usdc_xgboost_risk_level`

TUSD 與其他模型同樣依照 `{coin}_{model}_{field}` 命名。後端也提供 `system_max_risk_probability`、`usdc_kline_data`、`tusd_kline_data`，以及 `model_info`（按 USDC、TUSD 分組的模型說明）。

**分數與時間範圍提醒：** `depeg_probability` 是後端沿用的欄位名稱。目前前端將它當成 **0–100 的風險分數** 顯示，不能直接當成經過校準的脫鉤發生機率。雖然預估價格欄位名稱含有 `future_6h_low`，仍須依實際模型訓練目標判斷時間範圍，尤其不能只靠欄位名稱判定 TUSD 的所有模型都是 6 小時預測。

目前畫面可選擇 XGBoost、Transformer 0.99、Transformer 0.995；後端也有 `ensemble` 結果，但這不代表前端已把它列為獨立選項。

### K 線：`kline_data`

後端回傳的單筆 K 線使用 `time`、`open`、`high`、`low`、`close`、`vol`。前端也支援部分欄位別名：

- 時間：`Time`／`time`、`Timestamp`／`timestamp`、`Date`／`date`；可解析日期字串或 Unix 秒／毫秒。
- 價格：`Open`／`open` 等大小寫形式。
- 成交量：`Volume`／`volume`／`vol`。

前端會檢查價格高低是否合理、成交量是否為負數，並按時間排序及移除重複時間的 K 線。

## 錯誤處理與注意事項

- Binance 回傳非 2xx、空資料或不合格式時，前端會顯示錯誤。
- 後端回傳非 2xx 或 `success: false` 時，前端會視為請求失敗；後者使用 `error_message` 顯示原因。
- 後端推論程式目前將部分執行錯誤整理為 `{"success": false, "error_message": "..."}`，不一定會改用 4xx／5xx HTTP 狀態碼。
- 缺少必填資料、JSON 格式錯誤或欄位型別不符，可能讓前端解析失敗；請求驗證問題也可能由 FastAPI 回傳 422。
- 這份欄位紀錄已依現有原始碼核對，但尚不代表已完成線上部署、模型結果正確性或端到端測試。
