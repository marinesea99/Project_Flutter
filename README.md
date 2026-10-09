# 基於機器學習與深度學習之加密貨幣走勢預測與穩定幣脫鉤風險預警系統-前端

這裡放的是我們專題的 Flutter 前端程式。我主要負責網頁介面、API 資料串接和圖表呈現，將組員開發的後端模型輸出整理成可以查看、切換和比較的資訊。

**系統網站：** https://quantproject-frontend.onrender.com/

**後端程式：** [Project_backend](https://github.com/marinesea99/Project_backend)

## 目前的畫面與功能

- **加密貨幣走勢預測：** 支援 BTC、ETH、SOL、XRP，顯示目前價格、未來 4 小時方向分數、判斷門檻、偏多／偏空結果及資料時間。
- **穩定幣風險分析：** 支援 USDC、TUSD，可以選擇 XGBoost、Transformer 0.99、Transformer 0.995，查看模型輸出的價格與風險資訊。
- **K 線圖表：** 顯示開盤價、最高價、最低價、收盤價與成交量（OHLCV），支援切換幣種、查看圖表中的行情資料。
- **資料載入：** 提供重新取得資料、更新時間、逾時與錯誤提示。

模型的「上漲分數」和「風險分數」是模型計算結果，不代表未來一定會發生的機率。不同穩定幣模型也可能使用不同的預測目標與時間範圍。

## 前後端怎麼串接

目前前端會先從 Binance 公開 API 取得六種幣別的 1 小時 K 線資料，再將資料送往 Python 後端進行特徵處理及模型推論。後端回傳 JSON 後，由 Dart 負責解析資料並更新畫面。

前端實際使用的 API：

```text
POST /api/v1/dashboard/overview/from-klines
```

預設後端網址為 `https://quantproject-backend.onrender.com`，也可以透過 Flutter 的 `API_BASE_URL` 建置參數更換。

## 使用技術

| 項目 | 技術 |
| --- | --- |
| 前端 | Flutter、Dart |
| 網頁平台 | Flutter Web |
| API 與資料格式 | HTTP、JSON |
| 行情資料 | Binance 公開 K 線 API |
| 圖表繪製 | Flutter CustomPainter |

## 專案檔案

```text
Project_Flutter/
├── lib/main.dart            # 前端畫面、API 串接與圖表
├── web/                     # Flutter Web 入口及圖示
├── android/、ios/           # 行動平台設定
├── windows/、linux/、macos/ # 桌面平台設定
├── test/widget_test.dart    # 畫面與 K 線互動測試
├── docs/api-contract.md     # 前後端 API 欄位紀錄
├── pubspec.yaml             # Flutter 依賴設定
├── pubspec.lock             # 已解析的套件版本
├── analysis_options.yaml   # Dart 分析規則
├── SOURCE_ATTRIBUTION.md    # 團隊程式來源紀錄
└── README.md
```

`build/` 是 Flutter 編譯時產生的檔案，不需要放進 GitHub；相關平台與原始碼已保留。

`docs/api-contract.md` 已依目前的 POST API、後端回傳欄位與 K 線資料格式更新，串接方式請參考該文件與 `lib/main.dart`。

## 在本機執行

需要安裝 Flutter SDK 與 Chrome，並確保 Flutter 所附的 Dart SDK 符合專案的版本要求（目前 `pubspec.yaml` 設定 `^3.12.2`）。專案已包含 Flutter Web 與其他平台設定，下載後可直接安裝依賴並執行：

```bash
git clone https://github.com/marinesea99/Project_Flutter.git
cd Project_Flutter
flutter pub get
flutter run -d chrome
```

如需執行儲存庫中的測試，可使用 `flutter test`；測試通過與否仍須在本機環境確認。

如需指定另一個後端：

```bash
flutter run -d chrome --dart-define=API_BASE_URL=https://YOUR_BACKEND_HOST
```

執行時須能連線到行情 API 和後端服務。此儲存庫的程式與線上展示網站可能不是完全相同的部署版本。

## 專題分工

我負責 Flutter 介面的設計與調整，並把後端提供的加密貨幣預測、穩定幣風險資料和 K 線整合到畫面上，也參與系統測試與成果展示。模型研究及後端程式則由小組成員協作完成。

目前的 `lib/main.dart` 已整合團隊共享版本。原始程式來源記錄於 [SOURCE_ATTRIBUTION.md](SOURCE_ATTRIBUTION.md)。

本專題用於學術研究與成果展示，並非投資建議。
