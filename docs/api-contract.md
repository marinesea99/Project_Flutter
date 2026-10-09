# 前端 API 欄位規格

這份文件根據已提供的 Dart 前端程式撰寫，並非後端驗證報告。

## API

- `GET /api/v1/dashboard/overview`
- Header: `Accept: application/json`
- HTTP timeout: 15 seconds
- 支援 `{"success":true,"timestamp":"...","data":{...}}` 包裝格式；也兼容根節點直接放資料的舊版格式。

## 加密貨幣資料

`data.cryptos` 為陣列，單筆包含：

| 欄位 | 說明 |
| --- | --- |
| `coin` | BTC、ETH、SOL 或 XRP |
| `prediction_horizon_hours` | 正整數預測時數 |
| `up_score` | 0–100 上漲分數，不等於上漲機率 |
| `trend_label` | 預測趨勢標籤 |
| `display_threshold` | 0–100 判斷門檻 |
| `kline_interval` | K 棒週期，例如 1h |
| `kline_data` | OHLCV 陣列 |

K 棒時間接受 Time/time、Timestamp/timestamp、Date/date；價格支援 Open/High/Low/Close（大小寫形式）；成交量支援 Volume/volume/vol。

## 穩定幣資料

從 `data.stablecoins` 解析 USDC / TUSD，四個模型的欄位後綴分別為：

- `ensemble` → XGBoost+Transformer
- `transformer_0995` → Transformer0.995
- `transformer_099` → Transformer0.99
- `xgboost` → XGBoost

例如 `usdc_xgboost` 對應：

- `usdc_xgboost_current_price`
- `usdc_xgboost_future_6h_low`
- `usdc_xgboost_price_diff`
- `usdc_xgboost_depeg_probability`
- `usdc_xgboost_risk_level`

脫鉤機率由前端當作 0–100 的百分比數值，不是 0–1。穩定幣 K 棒欄位為 `usdc_kline_data`、`tusd_kline_data`。

## 注意

預測模型訓練與後端程式並未包含在目前儲存庫。API 回傳與部署設定仍需實際驗證。
