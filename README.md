# 基於機器學習與深度學習之加密貨幣走勢預測與穩定幣脫鉤風險預警系統

以 **Flutter / Dart** 開發的前端視覺化儀表板，整合後端提供的加密貨幣趨勢預測與穩定幣脫鉤風險資料，協助使用者透過 K 線、預測分數和風險指標了解模型輸出。

**🌐 線上系統展示：[開啟 Crypto Dashboard](https://quantproject-frontend.onrender.com/)**

> 本儲存庫目前提供 **Flutter 前端原始碼**與串接文件；後端 API、模型訓練程式和完整研究資料不在此儲存庫內。展示網站為獨立部署服務，可能與此處整理的前端程式版本有所不同。

## 專題介紹

專題涵蓋一般加密貨幣的價格走勢分析，以及穩定幣偏離美元錨定價格時的風險資訊呈現。前端透過 HTTP API 取得後端回傳的預測摘要、歷史 K 線及風險資料，轉換成可操作、可比較的儀表板。

### 系統主要功能

| 功能 | 支援內容 |
| --- | --- |
| 加密貨幣趨勢預測 | BTC、ETH、SOL、XRP；顯示上漲分數、判斷門檻、距門檻差、預測方向及預測時間範圍 |
| 穩定幣風險預警 | USDC、TUSD；顯示目前價格、未來六小時最低價、價格偏離、脫鉤機率與風險等級 |
| 多模型資訊比較 | XGBoost、Transformer0.99、Transformer0.995、XGBoost + Transformer |
| K 線視覺化 | OHLCV（開、高、低、收、成交量）與互動式圖表 |
| 使用者操作 | 幣種與模型複選、切換 K 線幣種、手動重新取得資料 |
| API 串接 | JSON 資料解析、逾時處理、錯誤提示與更新時間顯示 |

**注意：** 加密貨幣的 `up_score` 為後端提供的「上漲分數」，不應直接解讀成上漲機率；穩定幣的脫鉤機率則依 API 規格以百分比顯示。

## 線上展示

- **系統網址：** https://quantproject-frontend.onrender.com/
- **展示內容：** 加密貨幣趨勢資訊、穩定幣風險指標與互動式 K 線介面。
- **程式碼範圍：** 本儲存庫展示前端實作；線上系統是否可連線及其即時資料需視部署服務與後端狀態而定。

## 我的負責內容（Flutter 前端）

本儲存庫以我的前端實作為主，包含：

1. **前端介面設計：** 使用 Flutter 建立深色主題儀表板，並調整不同螢幕寬度下的版面。
2. **API 資料整合：** 使用 Dart 與 `http` 取得後端 JSON，解析幣種、模型指標及 OHLCV 資料。
3. **互動式 K 線圖：** 以 Flutter 自訂繪圖與互動元件呈現價格及成交量資訊。
4. **預測結果視覺化：** 將上漲分數、判斷門檻、趨勢標籤及穩定幣風險資料整理成介面欄位。
5. **狀態管理與例外處理：** 整合多幣種及多模型選取、更新操作、逾時與錯誤回饋。

> 上述描述的是前端實作及資料整合工作，不代表本儲存庫包含或由我獨立開發全部後端預測模型。

## 使用技術

| 類別 | 技術 |
| --- | --- |
| 前端框架 | Flutter |
| 程式語言 | Dart |
| API 串接 | HTTP REST API、JSON |
| 圖表繪製 | Flutter CustomPainter |
| 呈現平台 | Flutter Web |

## 專案結構

```text
Project_Flutter/
├── lib/
│   └── main.dart          # Flutter 前端儀表板主程式
├── docs/
│   ├── api-contract.md   # 前端預期的 API 欄位規格
│   └── notes.md          # 已納入與尚待補充的內容
├── pubspec.yaml          # Flutter 套件設定
├── .gitignore
├── .gitattributes
└── README.md
```

## 如何在本機執行

需要安裝 Flutter SDK、Chrome，並準備可以連線的後端 API。由於目前儲存庫尚未包含 Flutter Web 平台產生的全部檔案，首次執行請在儲存庫根目錄先建立 Web 平台腳手架：

```bash
flutter create --platforms=web .
flutter pub get
flutter run -d chrome --dart-define=API_BASE_URL=https://YOUR_BACKEND_HOST
```

建置正式 Web 版本：

```bash
flutter build web --release --dart-define=API_BASE_URL=https://YOUR_BACKEND_HOST
```

請將 `https://YOUR_BACKEND_HOST` 替換為**你自己的 API 主機網址**，不須加上 `/api/v1/dashboard/overview`。後端需正確設定 CORS；HTTPS 網頁應搭配 HTTPS API，避免瀏覽器阻擋混合內容。

此版使用 `String.fromEnvironment('API_BASE_URL')` 設定 API 主機，不再於公開原始碼中寫死後端 IP。**請勿在 `--dart-define` 中放入金鑰、密碼或權杖**，因為 Web 建置後的設定並非機密。

## 相關文件與開發狀態

- [前端 API 欄位規格](docs/api-contract.md)
- [專案整理說明](docs/notes.md)
- [線上系統展示](https://quantproject-frontend.onrender.com/)

此儲存庫目前為前端程式整理版本，尚未在本環境完成 Flutter 編譯、API 整合及端到端測試。未來若增加後端、模型、系統截圖與測試成果，將再補上對應文件。

---

**聲明：** 本專題供學術研究、系統實作與成果展示使用；預測分數及風險指標不構成投資建議。
