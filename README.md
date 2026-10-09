# 加密貨幣趨勢預測與穩定幣脫鉤風險預警系統

這是專題中 **Flutter / Dart 前端**的 GitHub 程式碼，呈現一般加密貨幣趨勢資料、穩定幣脫鉤風險資訊及互動式 K 線圖。

> 專案狀態：前端原始碼整理初版。後端 API 和模型訓練程式尚未收錄，尚未於此環境完成 Flutter 編譯與端到端測試。

## 功能介紹

- **BTC、ETH、SOL、XRP：** 可複選查看 K 線、上漲分數、判斷門檻、距門檻差、預測方向和預測時間範圍。
- **USDC、TUSD：** 可複選查看目前價格、未來六小時最低價、價格差、脫鉤機率和風險等級。
- **模型比較：** XGBoost、Transformer0.99、Transformer0.995、XGBoost+Transformer，支援複選。
- **OHLCV 圖表：** 使用 Flutter 的 CustomPainter 呈現互動式 K 線及成交量資訊。
- **API 整合：** 包含 JSON 解析、重新整理、請求逾時與錯誤訊息。
- **介面：** 深色主題，支援桌面與較窄螢幕尺寸。

## 專案結構

```text
Project_Flutter/
├── lib/
│   └── main.dart           # Flutter 前端主程式
├── docs/
│   ├── api-contract.md    # 前端預期的 API 欄位
│   └── notes.md           # 已提供與待補項目
├── pubspec.yaml           # Flutter 依賴
├── .gitignore
├── .gitattributes
└── README.md
```

## 本機啟動

需要安裝 Flutter SDK、Chrome 和可連線的後端服務。此儲存庫尚未附上 Flutter Web 的平台腳手架，因此首次啟動前，請先在專案根目錄執行：

```bash
flutter create --platforms=web .
flutter pub get
flutter run -d chrome --dart-define=API_BASE_URL=https://YOUR_BACKEND_HOST
```

正式建置：

```bash
flutter build web --release --dart-define=API_BASE_URL=https://YOUR_BACKEND_HOST
```

請將 `YOUR_BACKEND_HOST` 換成你自己的後端主機，**不要**附上 `/api/v1/dashboard/overview`。後端必須支援 CORS。若前端部署為 HTTPS，後端亦應提供 HTTPS，避免瀏覽器封鎖 HTTP 混合內容。

`API_BASE_URL` 會被編譯進 Web 產物，不能放金鑰、密碼等機密資料。這個初版已把原始程式中硬編碼的後端 IP 改成 `String.fromEnvironment('API_BASE_URL')`，其餘主要前端邏輯沿用提供的程式碼。

## 資料說明

- 一般幣種的 `up_score` 代表**上漲分數**，不是模型提供的上漲機率。
- 畫面中「模型資料截至時間」依 API 回應時間及最近已收盤 K 棒推算，不代表後端另有回傳獨立模型時間戳。
- 詳見 [前端 API 欄位規格](docs/api-contract.md) 和 [專案整理說明](docs/notes.md)。

本專案供學術研究與成果展示使用，介面指標不構成投資建議。
