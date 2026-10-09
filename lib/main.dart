import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// 應用程式進入點。
void main() {
  runApp(const CryptoDashboardApp());
}

/// 加密貨幣風險儀表板根元件。
class CryptoDashboardApp extends StatelessWidget {
  const CryptoDashboardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Crypto Dashboard',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2997FF),
          brightness: Brightness.dark,
        ),
      ),
      home: const CryptoDashboardPage(),
    );
  }
}

// ============================================================
// 1. 單一穩定幣模型資料
// ============================================================

/// USDC 或 TUSD 的單一模型五項輸出。
class StablecoinModelMetrics {
  final double currentPrice;
  final double future6hLow;
  final double priceDiff;
  final double riskScore;
  final String riskLevel;

  const StablecoinModelMetrics({
    required this.currentPrice,
    required this.future6hLow,
    required this.priceDiff,
    required this.riskScore,
    required this.riskLevel,
  });

  /// 依幣種與模型組合後的 JSON 前綴讀取五個欄位。
  ///
  /// 例如 prefix = tusd_ensemble，會讀取：
  /// - tusd_ensemble_current_price
  /// - tusd_ensemble_future_6h_low
  /// - tusd_ensemble_price_diff
  /// - tusd_ensemble_depeg_probability
  /// - tusd_ensemble_risk_level
  factory StablecoinModelMetrics.fromPayload(
    Map<String, dynamic> payload,
    String prefix,
  ) {
    return StablecoinModelMetrics(
      currentPrice: _readDouble(payload, '${prefix}_current_price'),
      future6hLow: _readDouble(payload, '${prefix}_future_6h_low'),
      priceDiff: _readDouble(payload, '${prefix}_price_diff'),
      riskScore: _readRiskScore(payload, '${prefix}_depeg_probability'),
      riskLevel: _readText(payload, '${prefix}_risk_level'),
    );
  }

  /// 接受 JSON number 或可轉換成 double 的字串。
  static double _readDouble(Map<String, dynamic> json, String key) {
    final value = json[key];

    if (value == null) {
      throw FormatException('JSON 缺少必要欄位：$key');
    }

    if (value is num) {
      return value.toDouble();
    }

    if (value is String) {
      final normalized = value
          .trim()
          .replaceAll('%', '')
          .replaceAll(',', '')
          .replaceAll(r'$', '');
      final parsed = double.tryParse(normalized);

      if (parsed != null) {
        return parsed;
      }
    }

    throw FormatException('欄位 $key 不是有效數字，收到：$value');
  }

  /// 後端沿用 depeg_probability 欄位名稱，但畫面只將數值視為風險分數。
  ///
  /// 例如後端回傳 25 或 "25%"，前端都轉成 0 到 100 的分數。
  static double _readRiskScore(Map<String, dynamic> json, String key) {
    return _readDouble(json, key).clamp(0.0, 100.0).toDouble();
  }

  /// risk_level 可接受字串或數字，最後統一轉成文字顯示。
  static String _readText(Map<String, dynamic> json, String key) {
    final value = json[key];

    if (value == null) {
      throw FormatException('JSON 缺少必要欄位：$key');
    }

    final text = value.toString().trim();

    if (text.isEmpty) {
      throw FormatException('欄位 $key 不可為空字串');
    }

    return text;
  }
}

// ============================================================
// 2. 儀表板資料模型與 API
// ============================================================

/// 後端單一時間週期的 OHLCV 資料。
class CandlestickData {
  final DateTime time;
  final double open;
  final double high;
  final double low;
  final double close;
  final double volume;

  const CandlestickData({
    required this.time,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
  });

  factory CandlestickData.fromJson(Map<String, dynamic> json) {
    final time = _readTime(json);
    final open = _readNumber(json, 'Open');
    final high = _readNumber(json, 'High');
    final low = _readNumber(json, 'Low');
    final close = _readNumber(json, 'Close');
    final volume = _readNumber(json, 'Volume', required: false);

    if (high < low || high < math.max(open, close)) {
      throw FormatException('$time 的 High 小於其他價格');
    }
    if (low > math.min(open, close)) {
      throw FormatException('$time 的 Low 大於開盤價或收盤價');
    }
    if (volume < 0) {
      throw FormatException('$time 的 Volume/vol 不可為負數');
    }

    return CandlestickData(
      time: time,
      open: open,
      high: high,
      low: low,
      close: close,
      volume: volume,
    );
  }

  static dynamic _valueFor(Map<String, dynamic> json, String key) {
    final value = json[key] ?? json[key.toLowerCase()];
    if (value != null) return value;

    // 目前後端使用 vol 作為成交量欄位。
    if (key == 'Volume') return json['vol'];
    return null;
  }

  static double _readNumber(
    Map<String, dynamic> json,
    String key, {
    bool required = true,
  }) {
    final value = _valueFor(json, key);

    if (value == null && !required) return 0;
    if (value is num) return value.toDouble();

    if (value is String) {
      final parsed = double.tryParse(value.trim().replaceAll(',', ''));
      if (parsed != null && parsed.isFinite) return parsed;
    }

    throw FormatException('K 線欄位 $key 不是有效數字，收到：$value');
  }

  static DateTime _readTime(Map<String, dynamic> json) {
    final value =
        json['Time'] ??
        json['time'] ??
        json['Timestamp'] ??
        json['timestamp'] ??
        json['Date'] ??
        json['date'];

    if (value is num) {
      // 同時接受 Unix 秒與 Unix 毫秒。
      final milliseconds = value.abs() < 100000000000
          ? (value * 1000).round()
          : value.round();
      return DateTime.fromMillisecondsSinceEpoch(milliseconds);
    }

    if (value is String) {
      final parsed = DateTime.tryParse(value.trim());
      if (parsed != null) return parsed;
    }

    throw FormatException('K 線缺少有效的 Time 欄位，收到：$value');
  }
}

class StablecoinModelDefinition {
  final String displayName;
  final List<String> components;
  final Map<String, int> featureCounts;

  const StablecoinModelDefinition({
    required this.displayName,
    required this.components,
    required this.featureCounts,
  });

  factory StablecoinModelDefinition.fromPayload(Map<String, dynamic> payload) {
    final rawComponents = payload['components'];
    final rawFeatureCounts = payload['feature_counts'];
    return StablecoinModelDefinition(
      displayName: payload['display_name']?.toString() ?? '未知模型',
      components: rawComponents is List
          ? rawComponents.map((value) => value.toString()).toList()
          : const [],
      featureCounts: rawFeatureCounts is Map
          ? Map<String, int>.fromEntries(
              rawFeatureCounts.entries.map(
                (entry) => MapEntry(
                  entry.key.toString(),
                  (entry.value as num).toInt(),
                ),
              ),
            )
          : const {},
    );
  }
}

class StablecoinRegressionDefinition {
  final String displayName;
  final int featureCount;

  const StablecoinRegressionDefinition({
    required this.displayName,
    required this.featureCount,
  });

  factory StablecoinRegressionDefinition.fromPayload(
    Map<String, dynamic> payload,
  ) {
    return StablecoinRegressionDefinition(
      displayName: payload['display_name']?.toString() ?? '未知模型',
      featureCount: (payload['feature_count'] as num?)?.toInt() ?? 0,
    );
  }
}

class StablecoinModelInfo {
  final int predictionHorizonHours;
  final String predictionTarget;
  final String klineInterval;
  final int inputKlineCount;
  final double? validationRocAuc;
  final String datasetPeriod;
  final Map<String, StablecoinModelDefinition> models;
  final List<StablecoinRegressionDefinition> regressionModels;

  const StablecoinModelInfo({
    required this.predictionHorizonHours,
    required this.predictionTarget,
    required this.klineInterval,
    required this.inputKlineCount,
    required this.validationRocAuc,
    required this.datasetPeriod,
    required this.models,
    required this.regressionModels,
  });

  factory StablecoinModelInfo.fromPayload(Map<String, dynamic> payload) {
    final models = <String, StablecoinModelDefinition>{};
    final rawModels = payload['models'];
    if (rawModels is List) {
      for (final rawModel in rawModels) {
        if (rawModel is! Map) continue;
        final model = StablecoinModelDefinition.fromPayload(
          Map<String, dynamic>.from(rawModel),
        );
        models[model.displayName] = model;
      }
    }
    final regressionModels = <StablecoinRegressionDefinition>[];
    final rawRegressionModels = payload['regression_models'];
    if (rawRegressionModels is List) {
      for (final rawModel in rawRegressionModels) {
        if (rawModel is! Map) continue;
        regressionModels.add(
          StablecoinRegressionDefinition.fromPayload(
            Map<String, dynamic>.from(rawModel),
          ),
        );
      }
    }

    return StablecoinModelInfo(
      predictionHorizonHours: (payload['prediction_horizon_hours'] as num)
          .toInt(),
      predictionTarget: payload['prediction_target'].toString(),
      klineInterval: payload['kline_interval'].toString(),
      inputKlineCount: (payload['input_kline_count'] as num).toInt(),
      validationRocAuc: payload['validation_roc_auc'] is num
          ? (payload['validation_roc_auc'] as num).toDouble()
          : null,
      datasetPeriod:
          payload['dataset_period']?.toString() ??
          '2023～2025 年 Binance 1h K 線資料',
      models: models,
      regressionModels: regressionModels,
    );
  }
}

class CryptoModelInfo {
  final String modelName;
  final String predictionTarget;
  final String targetDefinition;
  final int predictionHorizonHours;
  final int inputKlineCount;
  final int featureCount;
  final double displayThreshold;
  final double? validationRocAuc;
  final Map<String, String> trainingCoverage;

  const CryptoModelInfo({
    required this.modelName,
    required this.predictionTarget,
    required this.targetDefinition,
    required this.predictionHorizonHours,
    required this.inputKlineCount,
    required this.featureCount,
    required this.displayThreshold,
    required this.validationRocAuc,
    required this.trainingCoverage,
  });

  factory CryptoModelInfo.fromPayload(Map<String, dynamic> payload) {
    final rawCoverage = payload['training_coverage'];
    return CryptoModelInfo(
      modelName: payload['model_name'].toString(),
      predictionTarget: payload['prediction_target'].toString(),
      targetDefinition: payload['target_definition'].toString(),
      predictionHorizonHours: (payload['prediction_horizon_hours'] as num)
          .toInt(),
      inputKlineCount: (payload['input_kline_count'] as num).toInt(),
      featureCount: (payload['feature_count'] as num).toInt(),
      displayThreshold: (payload['display_threshold'] as num).toDouble(),
      validationRocAuc: payload['validation_roc_auc'] is num
          ? (payload['validation_roc_auc'] as num).toDouble()
          : null,
      trainingCoverage: rawCoverage is Map
          ? rawCoverage.map(
              (key, value) => MapEntry(key.toString(), value.toString()),
            )
          : const {},
    );
  }
}

class CryptoOverviewData {
  final String coin;
  final double currentPrice;
  final double upScore;
  final double thresholdGap;
  final String trendLabel;
  final String modelDataUntil;
  final String klineInterval;
  final List<CandlestickData> klineData;
  final CryptoModelInfo modelInfo;

  const CryptoOverviewData({
    required this.coin,
    required this.currentPrice,
    required this.upScore,
    required this.thresholdGap,
    required this.trendLabel,
    required this.modelDataUntil,
    required this.klineInterval,
    required this.klineData,
    required this.modelInfo,
  });

  factory CryptoOverviewData.fromPayload(Map<String, dynamic> payload) {
    final rawKlines = payload['kline_data'];
    final rawModelInfo = payload['model_info'];
    if (rawKlines is! List || rawModelInfo is! Map) {
      throw const FormatException('加密貨幣資料缺少 kline_data 或 model_info');
    }

    return CryptoOverviewData(
      coin: payload['coin'].toString(),
      currentPrice: (payload['current_price'] as num).toDouble(),
      upScore: (payload['up_score'] as num).toDouble(),
      thresholdGap: (payload['threshold_gap'] as num).toDouble(),
      trendLabel: payload['trend_label'].toString(),
      modelDataUntil: payload['model_data_until'].toString(),
      klineInterval: payload['kline_interval'].toString(),
      klineData: DashboardApi.parseCandles(rawKlines, 'kline_data'),
      modelInfo: CryptoModelInfo.fromPayload(
        Map<String, dynamic>.from(rawModelInfo),
      ),
    );
  }
}

class DashboardSnapshot {
  final Map<String, dynamic> stablecoinPayload;
  final Map<String, StablecoinModelInfo> stablecoinModelInfo;
  final Map<String, CryptoOverviewData> cryptos;
  final Map<String, List<CandlestickData>> klines;

  const DashboardSnapshot({
    required this.stablecoinPayload,
    required this.stablecoinModelInfo,
    required this.cryptos,
    required this.klines,
  });
}

class DashboardApi {
  static const String backendBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://quantproject-backend.onrender.com',
  );
  static const String overviewPath = '/api/v1/dashboard/overview/from-klines';
  static const String binanceBaseUrl =
      'https://data-api.binance.vision/api/v3/klines';
  static const Map<String, int> _symbolLimits = {
    'USDCUSDT': 100,
    'TUSDUSDT': 100,
    'BTCUSDT': 300,
    'ETHUSDT': 300,
    'SOLUSDT': 300,
    'XRPUSDT': 300,
  };

  static Future<DashboardSnapshot> fetchSnapshot() async {
    final entries = await Future.wait(
      _symbolLimits.entries.map((entry) async {
        final uri = Uri.parse(binanceBaseUrl).replace(
          queryParameters: {
            'symbol': entry.key,
            'interval': '1h',
            'limit': entry.value.toString(),
          },
        );
        final response = await http
            .get(uri, headers: const {'Accept': 'application/json'})
            .timeout(const Duration(seconds: 25));
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw Exception(
            'Binance ${entry.key} K 線讀取失敗：HTTP ${response.statusCode}',
          );
        }
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        if (decoded is! List || decoded.isEmpty) {
          throw FormatException('Binance ${entry.key} 沒有回傳有效 K 線');
        }
        return MapEntry(entry.key, decoded);
      }),
    );

    final uri = Uri.parse('$backendBaseUrl$overviewPath');
    final response = await http
        .post(
          uri,
          headers: const {
            'Accept': 'application/json',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'klines': Map.fromEntries(entries)}),
        )
        .timeout(const Duration(seconds: 180));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        '後端 API 呼叫失敗：HTTP ${response.statusCode}\n${response.body}',
      );
    }

    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map) {
      throw const FormatException('後端 API 回傳的 JSON 根節點必須是物件');
    }
    final root = Map<String, dynamic>.from(decoded);
    if (root['success'] != true) {
      throw Exception('後端推論失敗：${root['error_message'] ?? '未知錯誤'}');
    }
    final rawData = root['data'];
    if (rawData is! Map) {
      throw const FormatException('後端 JSON 缺少 data 物件');
    }
    final data = Map<String, dynamic>.from(rawData);
    final rawStablecoins = data['stablecoins'];
    final rawCryptos = data['cryptos'];
    if (rawStablecoins is! Map || rawCryptos is! List) {
      throw const FormatException('後端 JSON 缺少 stablecoins 或 cryptos');
    }

    final stablecoinPayload = Map<String, dynamic>.from(rawStablecoins);
    final stablecoinInfo = <String, StablecoinModelInfo>{};
    final rawStablecoinInfo = stablecoinPayload['model_info'];
    if (rawStablecoinInfo is Map) {
      for (final entry in rawStablecoinInfo.entries) {
        if (entry.value is Map) {
          stablecoinInfo[entry.key
              .toString()] = StablecoinModelInfo.fromPayload(
            Map<String, dynamic>.from(entry.value as Map),
          );
        }
      }
    }

    final cryptos = <String, CryptoOverviewData>{};
    for (final rawCrypto in rawCryptos) {
      if (rawCrypto is! Map) continue;
      final crypto = CryptoOverviewData.fromPayload(
        Map<String, dynamic>.from(rawCrypto),
      );
      cryptos[crypto.coin] = crypto;
    }

    final klines = <String, List<CandlestickData>>{};
    for (final coin in const ['USDC', 'TUSD']) {
      final key = '${coin.toLowerCase()}_kline_data';
      final rows = stablecoinPayload[key];
      if (rows is List) klines[coin] = parseCandles(rows, key);
    }
    for (final crypto in cryptos.values) {
      klines[crypto.coin] = crypto.klineData;
    }

    return DashboardSnapshot(
      stablecoinPayload: stablecoinPayload,
      stablecoinModelInfo: stablecoinInfo,
      cryptos: cryptos,
      klines: klines,
    );
  }

  static List<CandlestickData> parseCandles(List rows, String jsonKey) {
    final parsed = rows.map((row) {
      if (row is! Map) {
        throw FormatException('$jsonKey 中的每一筆資料都必須是物件');
      }
      return CandlestickData.fromJson(Map<String, dynamic>.from(row));
    }).toList()..sort((a, b) => a.time.compareTo(b.time));

    if (parsed.isEmpty) {
      throw FormatException('$jsonKey 沒有任何資料');
    }

    final uniqueByTime = <int, CandlestickData>{};
    for (final candle in parsed) {
      uniqueByTime[candle.time.millisecondsSinceEpoch] = candle;
    }

    return uniqueByTime.values.toList()
      ..sort((a, b) => a.time.compareTo(b.time));
  }
}

// ============================================================
// 3. 主畫面
// ============================================================

class CryptoDashboardPage extends StatefulWidget {
  const CryptoDashboardPage({super.key});

  @override
  State<CryptoDashboardPage> createState() => _CryptoDashboardPageState();
}

class _CryptoDashboardPageState extends State<CryptoDashboardPage> {
  final ScrollController _pageScrollController = ScrollController();

  // 模型顯示名稱。
  static const String modelTransformer0995 = 'Transformer0.995';
  static const String modelTransformer099 = 'Transformer0.99';
  static const String modelXGBoost = 'XGBoost';

  String _displayModelName(String modelName) {
    if (modelName == modelTransformer0995) return 'Transformer 0.995';
    if (modelName == modelTransformer099) return 'Transformer 0.99';
    return modelName;
  }

  String _classificationTarget(String coin, String modelName) {
    if (coin == 'USDC') {
      if (modelName == modelTransformer0995) {
        return '未來 6 小時最低收盤價是否低於 0.995';
      }
      if (modelName == modelTransformer099) {
        return '未來 6 小時最低收盤價是否低於 0.99';
      }
      return '未來 6 小時最低收盤價是否低於 0.995';
    }

    if (modelName == modelTransformer0995) {
      return '未來 24 小時最低價是否低於 0.995';
    }
    return '未來 24 小時最低價是否低於 0.99';
  }

  /// 模型顯示名稱對應 JSON 中的模型代稱。
  ///
  /// 最後的完整前綴會由「幣種代稱＋模型代稱」組成，例如：
  /// USDC + ensemble -> usdc_ensemble
  /// TUSD + xgboost -> tusd_xgboost
  static const Map<String, String> modelJsonSuffixes = {
    modelTransformer0995: 'transformer_0995',
    modelTransformer099: 'transformer_099',
    modelXGBoost: 'xgboost',
  };

  String? hoveredCategory;
  String? expandedCategory;
  String? selectedCategory;

  /// 幣種與模型皆支援複選。
  final List<String> selectedCoins = [];
  final List<String> selectedModels = [];

  bool isLoading = false;
  String? errorMessage;
  DateTime? lastUpdatedAt;

  Map<String, List<CandlestickData>> klineDataByCoin = const {};
  String selectedKlineCoin = 'USDC';
  bool isKlineLoading = false;
  String? klineErrorMessage;
  DateTime? klineLastUpdatedAt;
  CandlestickData? inspectedKlineCandle;
  String? inspectedKlineCoin;

  /// 第一層 key 是幣種，第二層 key 是模型顯示名稱。
  /// 例如：modelRiskData['USDC']?['XGBoost']。
  Map<String, Map<String, StablecoinModelMetrics>> modelRiskData = {};
  Map<String, dynamic> stablecoinPayload = {};
  Map<String, StablecoinModelInfo> stablecoinModelInfoByCoin = {};

  /// data.cryptos 的 BTC、ETH、SOL、XRP 預測資料。
  Map<String, CryptoOverviewData> cryptoOverviewByCoin = {};
  bool isCryptoLoading = false;
  String? cryptoErrorMessage;
  DateTime? cryptoLastUpdatedAt;

  /// 用來忽略較舊的非同步 API 回應。
  int _requestSerial = 0;

  final List<String> cryptoCoins = ['BTC', 'ETH', 'SOL', 'XRP'];
  final List<String> stableCoins = ['USDC', 'TUSD'];

  final List<String> models = const [
    modelTransformer0995,
    modelTransformer099,
    modelXGBoost,
  ];

  @override
  void initState() {
    super.initState();
    // K 線不在頁面初始化時載入。
    // 左側選到任一幣種後才會抓取並顯示。
  }

  @override
  void dispose() {
    _pageScrollController.dispose();
    super.dispose();
  }

  bool get isStableCoinCategory => selectedCategory == '穩定幣';
  bool get isCryptoCategory => selectedCategory == '加密貨幣';

  /// 目前選取的所有穩定幣，例如 [USDC, TUSD]。
  List<String> get selectedStablecoins {
    if (!isStableCoinCategory) {
      return const [];
    }
    return selectedCoins.where(stableCoins.contains).toList(growable: false);
  }

  /// 目前選取的一般加密貨幣。
  List<String> get selectedCryptos {
    if (!isCryptoCategory) {
      return const [];
    }
    return selectedCoins.where(cryptoCoins.contains).toList(growable: false);
  }

  bool get hasSelectedStablecoin => selectedStablecoins.isNotEmpty;

  /// 目前畫面可以切換顯示 K 線的幣種。
  List<String> get selectedKlineCoins {
    if (isStableCoinCategory) return selectedStablecoins;
    if (isCryptoCategory) return selectedCryptos;
    return const [];
  }

  bool get hasSelectedKlineCoin => selectedKlineCoins.isNotEmpty;

  List<CandlestickData> get activeKlineData {
    return klineDataByCoin[selectedKlineCoin] ?? const [];
  }

  /// 必須至少選一個穩定幣及一個模型。
  bool get canLoadStablecoinData {
    return selectedStablecoins.isNotEmpty && selectedModels.isNotEmpty;
  }

  bool get canRefreshSelectedData {
    return selectedCoins.isNotEmpty;
  }

  bool get isSelectedDataLoading =>
      isLoading || isCryptoLoading || isKlineLoading;

  /// 由幣種與模型名稱組合出 JSON 欄位前綴。
  String _jsonPrefixFor(String coin, String model) {
    final suffix = modelJsonSuffixes[model];

    if (suffix == null) {
      throw FormatException('找不到模型 $model 的 JSON 代稱設定');
    }

    return '${coin.toLowerCase()}_$suffix';
  }

  // ==========================================================
  // 4. API 載入與選項控制
  // ==========================================================

  Future<void> _loadDashboardData() async {
    if (selectedCoins.isEmpty) return;
    final requestId = ++_requestSerial;

    setState(() {
      isLoading = true;
      isKlineLoading = true;
      isCryptoLoading = true;
      errorMessage = null;
      klineErrorMessage = null;
      cryptoErrorMessage = null;
      inspectedKlineCandle = null;
      inspectedKlineCoin = null;
    });

    try {
      final snapshot = await DashboardApi.fetchSnapshot();
      if (!mounted || requestId != _requestSerial) return;
      final updatedAt = DateTime.now();

      setState(() {
        stablecoinPayload = snapshot.stablecoinPayload;
        stablecoinModelInfoByCoin = snapshot.stablecoinModelInfo;
        cryptoOverviewByCoin = snapshot.cryptos;
        klineDataByCoin = snapshot.klines;
        _updateStablecoinRiskFromCache();

        final availableSelected = selectedKlineCoins
            .where((coin) => snapshot.klines[coin]?.isNotEmpty ?? false)
            .toList(growable: false);
        if (availableSelected.isNotEmpty &&
            !availableSelected.contains(selectedKlineCoin)) {
          selectedKlineCoin = availableSelected.first;
        }
        inspectedKlineCandle = null;
        inspectedKlineCoin = null;

        lastUpdatedAt = updatedAt;
        klineLastUpdatedAt = updatedAt;
        cryptoLastUpdatedAt = updatedAt;
      });
    } on TimeoutException {
      if (!mounted || requestId != _requestSerial) return;
      setState(() {
        const message = '資料連線逾時；Render 免費主機喚醒時可能需要約一分鐘，請稍後重試。';
        errorMessage = message;
        klineErrorMessage = message;
        cryptoErrorMessage = message;
      });
    } on FormatException catch (error) {
      if (!mounted || requestId != _requestSerial) return;
      setState(() {
        final message = 'JSON 格式錯誤：${error.message}';
        errorMessage = message;
        klineErrorMessage = message;
        cryptoErrorMessage = message;
      });
    } catch (error) {
      if (!mounted || requestId != _requestSerial) return;
      setState(() {
        final message = '讀取資料失敗：$error';
        errorMessage = message;
        klineErrorMessage = message;
        cryptoErrorMessage = message;
      });
    } finally {
      if (mounted && requestId == _requestSerial) {
        setState(() {
          isLoading = false;
          isKlineLoading = false;
          isCryptoLoading = false;
        });
      }
    }
  }

  void _updateStablecoinRiskFromCache() {
    final parsedData = <String, Map<String, StablecoinModelMetrics>>{};
    for (final coin in selectedStablecoins) {
      final coinData = <String, StablecoinModelMetrics>{};
      for (final model in selectedModels) {
        final prefix = _jsonPrefixFor(coin, model);
        coinData[model] = StablecoinModelMetrics.fromPayload(
          stablecoinPayload,
          prefix,
        );
      }
      parsedData[coin] = coinData;
    }
    modelRiskData = parsedData;
  }

  Future<void> _loadKlineData() => _loadDashboardData();
  Future<void> _loadStablecoinRisk() => _loadDashboardData();
  Future<void> _loadCryptoOverview() => _loadDashboardData();
  Future<void> _refreshSelectedData() => _loadDashboardData();

  void _resetCryptoResult() {
    isCryptoLoading = false;
    cryptoErrorMessage = null;
  }

  /// 清除目前 API 結果，但不直接清空左側選項。
  void _resetApiResult() {
    _requestSerial++;
    isLoading = false;
    modelRiskData = {};
    errorMessage = null;
  }

  bool _hasSelectedCategory(String category) {
    if (selectedCategory != category) return false;

    if (category == '加密貨幣') {
      return selectedCoins.isNotEmpty;
    }

    return selectedCoins.isNotEmpty || selectedModels.isNotEmpty;
  }

  /// 切換幣種；同一分類中的幣種可複選。
  void _toggleCoin(String category, String coin) {
    var shouldLoadDashboard = false;

    setState(() {
      if (selectedCategory != category) {
        selectedCategory = category;
        selectedCoins.clear();
        selectedModels.clear();
        _resetApiResult();
        _resetCryptoResult();
      }

      if (selectedCoins.contains(coin)) {
        selectedCoins.remove(coin);
      } else {
        selectedCoins.add(coin);
        selectedKlineCoin = coin;
      }
      inspectedKlineCandle = null;
      inspectedKlineCoin = null;

      if (category == '穩定幣') {
        if (selectedCoins.isEmpty) {
          selectedModels.clear();
        }
      } else {
        selectedModels.clear();
        _resetApiResult();
        _resetCryptoResult();
      }

      if (selectedKlineCoin == coin && !selectedCoins.contains(coin)) {
        if (selectedCoins.isNotEmpty) selectedKlineCoin = selectedCoins.first;
      }

      if (stablecoinPayload.isNotEmpty) {
        _updateStablecoinRiskFromCache();
      }
      shouldLoadDashboard =
          selectedCoins.isNotEmpty &&
          klineDataByCoin.isEmpty &&
          !isSelectedDataLoading;
    });

    if (shouldLoadDashboard) _loadDashboardData();
  }

  /// 模型可複選；後端完整結果已載入時只需重新整理畫面資料。
  void _toggleModel(String model) {
    if (!hasSelectedStablecoin) {
      return;
    }

    setState(() {
      if (selectedModels.contains(model)) {
        selectedModels.remove(model);
      } else {
        selectedModels.add(model);
      }

      errorMessage = null;
      if (stablecoinPayload.isNotEmpty) {
        _updateStablecoinRiskFromCache();
      }
    });

    if (canLoadStablecoinData &&
        stablecoinPayload.isEmpty &&
        !isSelectedDataLoading) {
      _loadDashboardData();
    }
  }

  void _clearSelection() {
    setState(() {
      selectedCategory = null;
      selectedCoins.clear();
      selectedModels.clear();
      _resetApiResult();
      _resetCryptoResult();
      _requestSerial++;
      isKlineLoading = false;
      isCryptoLoading = false;
      klineErrorMessage = null;
      inspectedKlineCandle = null;
      inspectedKlineCoin = null;
    });
  }

  // ==========================================================
  // 5. 頁面版面
  // ==========================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isDesktop = constraints.maxWidth >= 900;
            final isMobile = constraints.maxWidth < 600;
            final leftPanel = _buildLeftPanel();
            final rightPanel = _buildRightPanel(isMobile: isMobile);

            final content = isDesktop
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(width: 290, child: leftPanel),
                      const SizedBox(width: 16),
                      Expanded(child: rightPanel),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      leftPanel,
                      const SizedBox(height: 20),
                      rightPanel,
                    ],
                  );

            return SingleChildScrollView(
              controller: _pageScrollController,
              padding: EdgeInsets.all(isDesktop ? 18 : 16),
              child: content,
            );
          },
        ),
      ),
    );
  }

  Widget _buildLeftPanel() {
    return Container(
      padding: const EdgeInsets.all(28),
      decoration: _panelDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '加密貨幣儀表板',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            '一般加密貨幣可複選 BTC、ETH、SOL、XRP；'
            '穩定幣可複選 USDC、TUSD 與分類模型；結果區另列迴歸模型比較。',
            style: TextStyle(
              fontSize: 13,
              height: 1.5,
              color: Colors.white.withValues(alpha: 0.55),
            ),
          ),
          const SizedBox(height: 32),
          _buildHoverCategoryMenu(
            category: '加密貨幣',
            subtitle: 'BTC、ETH、SOL、XRP 的 4h 趨勢預測',
            coins: cryptoCoins,
            showModels: false,
          ),
          const SizedBox(height: 12),
          _buildHoverCategoryMenu(
            category: '穩定幣',
            subtitle: 'USDC、TUSD、三個分類模型與兩個迴歸模型',
            coins: stableCoins,
            showModels: true,
          ),
          if (selectedCoins.isNotEmpty || selectedModels.isNotEmpty) ...[
            const SizedBox(height: 24),
            _buildSelectedSummary(),
          ],
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: !canRefreshSelectedData || isSelectedDataLoading
                  ? null
                  : _refreshSelectedData,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(isSelectedDataLoading ? '讀取中...' : '重新抓取資料'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRightPanel({required bool isMobile}) {
    final viewportHeight = MediaQuery.sizeOf(context).height;
    final chartHeight = isMobile
        ? 480.0
        : (viewportHeight * 0.62).clamp(420.0, 560.0).toDouble() + 40.0;

    // 只要目前「沒有實際選到任何幣種或模型」，
    // 不論 selectedCategory 是否仍保留先前的分類，都視為空白狀態。
    //
    // 這樣使用者把左側 USDC / TUSD 等選項逐一取消後，
    // 右側資料顯示區就會恢復成初始的大尺寸，不會縮成 220 px。
    final isEmptySelection = selectedCoins.isEmpty && selectedModels.isEmpty;

    // 空白狀態約佔視窗高度 70%，並限制在 520～650 px。
    // 有實際選擇時才恢復原本較精簡的高度。
    final resultPanelMinHeight = isEmptySelection
        ? (viewportHeight * 0.70).clamp(520.0, 650.0).toDouble()
        : 220.0;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _panelDecoration(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 左側選到 USDC/TUSD 或 BTC 時顯示右上方 K 線圖。
          if (hasSelectedKlineCoin) ...[
            SizedBox(
              height: chartHeight,
              child: _buildKlinePanel(isMobile: isMobile),
            ),
            const SizedBox(height: 16),
          ],
          ConstrainedBox(
            constraints: BoxConstraints(minHeight: resultPanelMinHeight),
            child: _buildApiResultPanel(),
          ),
          const SizedBox(height: 16),
          _buildDisclaimerPanel(),
        ],
      ),
    );
  }

  Widget _buildKlinePanel({required bool isMobile}) {
    final candles = activeKlineData;
    final latest = candles.isEmpty ? null : candles.last;
    final inspected = inspectedKlineCoin == selectedKlineCoin
        ? inspectedKlineCandle
        : null;
    final displayed = inspected ?? latest;
    final displayedColor =
        displayed == null || displayed.close >= displayed.open
        ? const Color(0xFFFF453A)
        : const Color(0xFF30D158);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF0D0D0F),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.candlestick_chart_rounded,
                size: 25,
                color: Color(0xFF64D2FF),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$selectedKlineCoin 1h K 線圖',
                      style: const TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      klineLastUpdatedAt == null
                          ? 'OHLCV 即時資料'
                          : '最後更新：${_formatTime(klineLastUpdatedAt!)}',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white.withValues(alpha: 0.42),
                      ),
                    ),
                  ],
                ),
              ),
              _buildChartLegend(const Color(0xFFFF453A), '漲'),
              const SizedBox(width: 9),
              _buildChartLegend(const Color(0xFF30D158), '跌'),
              const SizedBox(width: 4),
              IconButton(
                tooltip: '重新抓取 K 線',
                onPressed: isKlineLoading ? null : _loadKlineData,
                icon: isKlineLoading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh_rounded, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              // 只顯示目前分類中有後端 K 線資料的已選幣種。
              for (int i = 0; i < selectedKlineCoins.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                _buildKlineCoinButton(selectedKlineCoins[i]),
              ],
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  isMobile
                      ? '${candles.length} 根 · 點選鎖定 · 滑動平移'
                      : '${candles.length} 根 · 滑鼠查看／點擊鎖定 · 拖曳平移 · 滾輪縮放',
                  maxLines: 2,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.white.withValues(alpha: 0.42),
                  ),
                ),
              ),
            ],
          ),
          if (displayed != null) ...[
            const SizedBox(height: 12),
            Text(
              inspected == null
                  ? '最新 1h K 棒 · ${_formatTime(displayed.time)}'
                  : '指定 1h K 棒 · ${_formatTime(displayed.time)}',
              style: TextStyle(
                fontSize: 11,
                color: inspected == null
                    ? Colors.white.withValues(alpha: 0.42)
                    : const Color(0xFF64D2FF),
              ),
            ),
            const SizedBox(height: 5),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _buildKlineValue('開', _formatKlineNumber(displayed.open)),
                  _buildKlineValue('高', _formatKlineNumber(displayed.high)),
                  _buildKlineValue('低', _formatKlineNumber(displayed.low)),
                  _buildKlineValue(
                    '收',
                    _formatKlineNumber(displayed.close),
                    valueColor: displayedColor,
                  ),
                  _buildKlineValue(
                    '成交量 ($selectedKlineCoin)',
                    _formatVolume(displayed.volume),
                  ),
                ],
              ),
            ),
          ],
          if (klineErrorMessage != null && klineDataByCoin.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              klineErrorMessage!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Colors.orangeAccent),
            ),
          ],
          const SizedBox(height: 8),
          Expanded(child: _buildKlineChartBody(isMobile: isMobile)),
        ],
      ),
    );
  }

  Widget _buildKlineChartBody({required bool isMobile}) {
    final candles = activeKlineData;

    if (isKlineLoading && klineDataByCoin.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (klineErrorMessage != null && klineDataByCoin.isEmpty) {
      return Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.orangeAccent),
              const SizedBox(height: 8),
              Text(
                klineErrorMessage!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.orangeAccent,
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _loadKlineData,
                icon: const Icon(Icons.refresh_rounded, size: 17),
                label: const Text('重試'),
              ),
            ],
          ),
        ),
      );
    }

    if (candles.isEmpty) {
      return Center(
        child: Text(
          '尚無 K 線資料',
          style: TextStyle(color: Colors.white.withValues(alpha: 0.45)),
        ),
      );
    }

    return InteractiveCandlestickChart(
      candles: candles,
      mobileMode: isMobile,
      onInspectionChanged: (candle) {
        if (!mounted) return;
        setState(() {
          inspectedKlineCandle = candle;
          inspectedKlineCoin = candle == null ? null : selectedKlineCoin;
        });
      },
    );
  }

  Widget _buildKlineCoinButton(String coin) {
    final isSelected = selectedKlineCoin == coin;
    final isAvailable =
        selectedKlineCoins.contains(coin) &&
        (klineDataByCoin[coin]?.isNotEmpty ?? false);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(7),
        onTap: isAvailable
            ? () {
                setState(() {
                  selectedKlineCoin = coin;
                  inspectedKlineCandle = null;
                  inspectedKlineCoin = null;
                });
              }
            : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
          decoration: BoxDecoration(
            color: isSelected
                ? const Color(0xFF2997FF).withValues(alpha: 0.2)
                : Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
              color: isSelected
                  ? const Color(0xFF2997FF).withValues(alpha: 0.8)
                  : Colors.white.withValues(alpha: 0.08),
            ),
          ),
          child: Text(
            coin,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: !isAvailable
                  ? Colors.white.withValues(alpha: 0.28)
                  : isSelected
                  ? const Color(0xFF64D2FF)
                  : Colors.white.withValues(alpha: 0.68),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildChartLegend(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: Colors.white.withValues(alpha: 0.55),
          ),
        ),
      ],
    );
  }

  Widget _buildKlineValue(String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.only(right: 14),
      child: Text.rich(
        TextSpan(
          style: const TextStyle(fontSize: 13),
          children: [
            TextSpan(
              text: '$label ',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.42)),
            ),
            TextSpan(
              text: value,
              style: TextStyle(
                color: valueColor ?? Colors.white.withValues(alpha: 0.78),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  BoxDecoration _panelDecoration() {
    return BoxDecoration(
      color: const Color(0xFF161617),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.35),
          blurRadius: 24,
          offset: const Offset(0, 14),
        ),
      ],
    );
  }

  // ==========================================================
  // 6. 右側多幣種、多模型資料區域
  // ==========================================================

  Widget _buildApiResultPanel() {
    if (isCryptoCategory) {
      return _buildCryptoResultPanel();
    }

    final coins = selectedStablecoins;

    if (coins.isEmpty) {
      return _buildEmptyState(
        icon: Icons.currency_exchange_rounded,
        title: '請先選擇加密貨幣或穩定幣其一',
        message: '從左側選單進行選擇，至少選擇一個幣種。',
      );
    }

    if (selectedModels.isEmpty) {
      return _buildEmptyState(
        icon: Icons.model_training_rounded,
        title: '請選擇預測模型',
        message: '目前幣種為 ${coins.join('、')}；三個分類模型皆支援同時複選。',
      );
    }

    if (isLoading && modelRiskData.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (errorMessage != null && modelRiskData.isEmpty) {
      return _buildErrorPanel();
    }

    if (modelRiskData.isEmpty) {
      return _buildEmptyState(
        icon: Icons.cloud_download_outlined,
        title: '尚未取得模型資料',
        message: '請按下重新抓取按鈕，或重新勾選幣種與模型。',
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '多幣種、多模型風險資料',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (isLoading)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          '已選幣種：${coins.join('、')}　｜　已選模型：${selectedModels.map(_displayModelName).join('、')}',
          style: TextStyle(
            fontSize: 12,
            color: Colors.white.withValues(alpha: 0.45),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          lastUpdatedAt == null
              ? '尚未更新'
              : '最後更新：${_formatTime(lastUpdatedAt!)}',
          style: TextStyle(
            fontSize: 12,
            color: Colors.white.withValues(alpha: 0.45),
          ),
        ),
        if (errorMessage != null) ...[
          const SizedBox(height: 14),
          _buildWarningBanner(errorMessage!),
        ],
        const SizedBox(height: 12),
        for (int coinIndex = 0; coinIndex < coins.length; coinIndex++) ...[
          _buildCoinResultSection(coin: coins[coinIndex]),
          if (coinIndex != coins.length - 1) const SizedBox(height: 20),
        ],
      ],
    );
  }

  Widget _buildCryptoResultPanel() {
    final coins = selectedCryptos;

    if (coins.isEmpty) {
      return _buildEmptyState(
        icon: Icons.currency_bitcoin_rounded,
        title: '請選擇加密貨幣',
        message: '可複選 BTC、ETH、SOL、XRP，查看 4h 趨勢預測與 1h K 線。',
      );
    }

    if (isCryptoLoading && cryptoOverviewByCoin.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (cryptoErrorMessage != null && cryptoOverviewByCoin.isEmpty) {
      return Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 560),
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.redAccent.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.redAccent.withValues(alpha: 0.35)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline_rounded,
                size: 42,
                color: Colors.redAccent,
              ),
              const SizedBox(height: 16),
              SelectableText(
                cryptoErrorMessage!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.redAccent, height: 1.5),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: _loadCryptoOverview,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('重試'),
              ),
            ],
          ),
        ),
      );
    }

    final availableCoins = coins
        .where(cryptoOverviewByCoin.containsKey)
        .toList(growable: false);
    if (availableCoins.isEmpty) {
      return _buildEmptyState(
        icon: Icons.cloud_download_outlined,
        title: '尚未取得加密貨幣預測資料',
        message: '請按下重新抓取資料。',
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${availableCoins.join('、')} 4h 趨勢預測',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
            ),
            if (isCryptoLoading)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          cryptoLastUpdatedAt == null
              ? '尚未更新'
              : '最後更新：${_formatTime(cryptoLastUpdatedAt!)}',
          style: TextStyle(
            fontSize: 12,
            color: Colors.white.withValues(alpha: 0.45),
          ),
        ),
        if (cryptoErrorMessage != null) ...[
          const SizedBox(height: 14),
          _buildWarningBanner(cryptoErrorMessage!),
        ],
        const SizedBox(height: 14),
        for (int index = 0; index < availableCoins.length; index++) ...[
          _buildCryptoCoinSection(cryptoOverviewByCoin[availableCoins[index]]!),
          if (index != availableCoins.length - 1) const SizedBox(height: 20),
        ],
      ],
    );
  }

  Widget _buildCryptoCoinSection(CryptoOverviewData data) {
    final directionColor = _trendColor(data.trendLabel);
    final metrics = <Widget>[
      _buildCompactMetricCell(
        title: '目前價格',
        value: _formatCryptoPrice(data.currentPrice),
        jsonKey: 'current_price',
        subtitle: '${data.coin} 最新 1h K 線收盤價',
        color: const Color(0xFF64D2FF),
      ),
      _buildCompactMetricCell(
        title: '4h 上漲分數',
        value: _formatPercent(data.upScore),
        jsonKey: 'up_score',
        subtitle: '模型輸出的 4 小時上漲分數；不是保證機率',
        color: const Color(0xFFBF5AF2),
      ),
      _buildCompactMetricCell(
        title: '距門檻差',
        value: _formatSignedPercentPoints(data.thresholdGap),
        jsonKey: 'threshold_gap',
        subtitle: '上漲分數減去模型判定門檻',
        color: data.thresholdGap >= 0
            ? const Color(0xFF30D158)
            : const Color(0xFFFF453A),
      ),
      _buildCompactMetricCell(
        title: '預測方向',
        value: data.trendLabel,
        jsonKey: 'trend_label',
        subtitle: '${data.modelInfo.predictionHorizonHours} 小時方向判定',
        color: directionColor,
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildCoinHeading(data.coin),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 760
                ? 4
                : constraints.maxWidth >= 390
                ? 2
                : 1;
            const spacing = 8.0;
            final cardWidth =
                (constraints.maxWidth - spacing * (columns - 1)) / columns;
            return Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: [
                for (final metric in metrics)
                  SizedBox(width: cardWidth, child: metric),
              ],
            );
          },
        ),
        const SizedBox(height: 10),
        _buildCryptoModelInfo(data),
      ],
    );
  }

  Widget _buildCryptoModelInfo(CryptoOverviewData data) {
    final info = data.modelInfo;
    final trainingRange = _formatCoverageRange(
      info.trainingCoverage,
      'train_start',
      'train_end',
    );
    final validationRange = _formatCoverageRange(
      info.trainingCoverage,
      'validation_start',
      'validation_end',
    );
    final auc = info.validationRocAuc == null
        ? '未記錄'
        : info.validationRocAuc!.toStringAsFixed(4);
    return _buildModelInfoPanel(
      title: '${data.coin} 模型介紹',
      description:
          '${info.modelName} 使用最近 ${info.inputKlineCount} 根 ${data.klineInterval} K 線與 '
          '${info.featureCount} 個特徵，預測${info.predictionTarget}。',
      items: {
        '判定方式': info.targetDefinition,
        '方向門檻': _formatPercent(info.displayThreshold),
        '驗證 ROC-AUC': auc,
        if (trainingRange.isNotEmpty) '訓練資料範圍': trainingRange,
        if (validationRange.isNotEmpty) '驗證資料範圍': validationRange,
        '模型資料截至': data.modelDataUntil,
      },
    );
  }

  String _formatCoverageRange(
    Map<String, String> coverage,
    String startKey,
    String endKey,
  ) {
    final start = coverage[startKey];
    final end = coverage[endKey];
    if (start == null || end == null) return '';
    String normalize(String value) => value.replaceFirst('+00:00', ' UTC');
    return '${normalize(start)} ～ ${normalize(end)}';
  }

  /// 依任務顯示單一幣種的市場資料、分類監測與迴歸估計。
  Widget _buildCoinResultSection({required String coin}) {
    final coinData =
        modelRiskData[coin] ?? const <String, StablecoinModelMetrics>{};
    final firstData = coinData.values.firstOrNull;
    final selectedTransformer = selectedModels
        .where(
          (modelName) =>
              modelName == modelTransformer0995 ||
              modelName == modelTransformer099,
        )
        .firstOrNull;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildCoinHeading(coin),
        if (firstData != null) ...[
          const SizedBox(height: 10),
          _buildTaskHeading(
            icon: Icons.currency_exchange_rounded,
            title: '市場資料',
            description: '最新一根 1h K 線的收盤價，供模型輸出比較使用。',
          ),
          const SizedBox(height: 7),
          SizedBox(
            width: 260,
            child: _buildCompactMetricCell(
              title: '目前價格',
              value: _formatUsd(firstData.currentPrice),
              jsonKey: '${coin.toLowerCase()}_current_price',
              subtitle: '$coin 最新市場價格',
              color: const Color(0xFF64D2FF),
            ),
          ),
        ],
        const SizedBox(height: 16),
        _buildTaskHeading(
          icon: Icons.notification_important_outlined,
          title: '分類模型監測',
          description: '各模型依自己的標籤輸出未校準風險分數，不視為事件發生機率。',
        ),
        const SizedBox(height: 7),
        for (final modelName in selectedModels) ...[
          if (coinData[modelName] != null)
            _buildClassificationModelSection(
              coin: coin,
              modelName: modelName,
              data: coinData[modelName]!,
            ),
          const SizedBox(height: 8),
        ],
        const SizedBox(height: 8),
        _buildTaskHeading(
          icon: Icons.show_chart_rounded,
          title: '迴歸模型比較',
          description: '比較 Transformer 與 XGBoost 對未來 6 小時最低價格的估計。',
        ),
        const SizedBox(height: 7),
        if (selectedTransformer != null &&
            coinData[selectedTransformer] != null) ...[
          _buildRegressionModelSection(
            coin: coin,
            modelName: 'Transformer Regression',
            data: coinData[selectedTransformer]!,
            jsonModelName: selectedTransformer,
          ),
          const SizedBox(height: 8),
        ],
        if (selectedModels.contains(modelXGBoost) &&
            coinData[modelXGBoost] != null)
          _buildRegressionModelSection(
            coin: coin,
            modelName: 'XGBoost Regression',
            data: coinData[modelXGBoost]!,
            jsonModelName: modelXGBoost,
          ),
        if (stablecoinModelInfoByCoin[coin] != null) ...[
          const SizedBox(height: 16),
          _buildStablecoinModelInfo(coin),
        ],
      ],
    );
  }

  Widget _buildStablecoinModelInfo(String coin) {
    final info = stablecoinModelInfoByCoin[coin]!;
    final selectedDefinitions = selectedModels
        .map((name) => info.models[name])
        .whereType<StablecoinModelDefinition>()
        .toList(growable: false);
    final components = selectedDefinitions
        .expand((model) => model.components)
        .toSet()
        .join('、');
    final featureDetails = selectedDefinitions
        .map((model) {
          final counts = model.featureCounts.entries
              .map((entry) {
                final role = switch (entry.key) {
                  'classifier' => '分類',
                  'regressor' => '迴歸',
                  _ => entry.key,
                };
                return '$role ${entry.value}';
              })
              .join('、');
          return '${_displayModelName(model.displayName)}：$counts';
        })
        .join('；');
    final classificationTargets = selectedModels
        .map(
          (modelName) =>
              '${_displayModelName(modelName)}：${_classificationTarget(coin, modelName)}',
        )
        .join('；');
    final regressionNames = info.regressionModels
        .map((model) => model.displayName)
        .join('、');
    final regressionFeatures = info.regressionModels
        .map((model) => '${model.displayName}：${model.featureCount}')
        .join('；');
    return _buildModelInfoPanel(
      title: '$coin 模型介紹',
      description: '本系統將即時狀態監測、未來脫鉤預警與價格迴歸分開呈現。',
      items: {
        '目前顯示分類模型': selectedModels.map(_displayModelName).join('、'),
        '輸入資料': '最近 ${info.inputKlineCount} 根 ${info.klineInterval} K 線',
        '資料集涵蓋期間': info.datasetPeriod,
        '分類目標': classificationTargets,
        if (regressionNames.isNotEmpty) '迴歸比較模型': regressionNames,
        '迴歸比較口徑': 'Transformer、XGBoost：未來 6 小時最低價格',
        if (regressionFeatures.isNotEmpty) '迴歸特徵數': regressionFeatures,
        '輸出說明': '分類值為未校準風險分數（0–100），不是發生機率',
        if (components.isNotEmpty) '模型組成': components,
        if (featureDetails.isNotEmpty) '特徵數': featureDetails,
        if (info.validationRocAuc != null)
          '驗證 ROC-AUC': info.validationRocAuc!.toStringAsFixed(4),
      },
    );
  }

  Widget _buildTaskHeading({
    required IconData icon,
    required String title,
    required String description,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 17, color: const Color(0xFF64D2FF)),
        const SizedBox(width: 7),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                description,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.4,
                  color: Colors.white.withValues(alpha: 0.48),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _taskType(String coin, String modelName) {
    return '未來區間預警';
  }

  String _taskHorizon(String coin, String modelName) {
    return coin == 'USDC' ? '未來 6 小時' : '未來 24 小時';
  }

  String _regressionHorizon(String coin, String modelName) {
    // TODO: TUSD XGBoost 舊權重仍為 24 小時目標，需換成 6 小時重訓權重。
    return '6 小時';
  }

  Widget _buildClassificationModelSection({
    required String coin,
    required String modelName,
    required StablecoinModelMetrics data,
  }) {
    final prefix = _jsonPrefixFor(coin, modelName);
    final displayModelName = _displayModelName(modelName);

    final metrics = <Widget>[
      _buildCompactMetricCell(
        title: '脫鉤風險分數',
        value: _formatRiskScore(data.riskScore),
        jsonKey: '${prefix}_depeg_probability',
        subtitle: '${_classificationTarget(coin, modelName)}；此分數不是發生機率',
        color: _riskScoreColor(data.riskScore),
      ),
      _buildCompactMetricCell(
        title: '監測等級',
        value: _displayRiskLevel(data.riskLevel),
        jsonKey: '${prefix}_risk_level',
        subtitle: '依風險分數區間顯示，不代表事件一定發生',
        color: _riskLevelColor(data.riskLevel, data.riskScore),
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFF0D0D0F),
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
              color: const Color(0xFF2997FF).withValues(alpha: 0.18),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    const Icon(
                      Icons.analytics_outlined,
                      size: 15,
                      color: Color(0xFF2997FF),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        displayModelName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _taskType(coin, modelName),
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.white.withValues(alpha: 0.55),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 7),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.025),
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
          ),
          child: Wrap(
            spacing: 18,
            runSpacing: 5,
            children: [
              Text(
                '預測目標：${_classificationTarget(coin, modelName)}',
                style: TextStyle(
                  fontSize: 11,
                  height: 1.4,
                  color: Colors.white.withValues(alpha: 0.68),
                ),
              ),
              Text(
                '時間範圍：${_taskHorizon(coin, modelName)}',
                style: TextStyle(
                  fontSize: 11,
                  height: 1.4,
                  color: Colors.white.withValues(alpha: 0.68),
                ),
              ),
              Text(
                '輸出性質：未校準風險分數',
                style: TextStyle(
                  fontSize: 11,
                  height: 1.4,
                  color: Colors.white.withValues(alpha: 0.68),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 7),
        LayoutBuilder(
          builder: (context, constraints) {
            final int columns;
            if (constraints.maxWidth >= 390) {
              columns = 2;
            } else {
              columns = 1;
            }

            const spacing = 8.0;
            final cardWidth =
                (constraints.maxWidth - spacing * (columns - 1)) / columns;

            return Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: [
                for (final metric in metrics)
                  SizedBox(width: cardWidth, child: metric),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _buildRegressionModelSection({
    required String coin,
    required String modelName,
    required String jsonModelName,
    required StablecoinModelMetrics data,
  }) {
    final prefix = _jsonPrefixFor(coin, jsonModelName);
    final horizon = _regressionHorizon(coin, modelName);
    final metrics = <Widget>[
      _buildCompactMetricCell(
        title: '$horizon最低價估計',
        value: _formatUsd(data.future6hLow),
        jsonKey: '${prefix}_future_6h_low',
        subtitle: '$modelName 對未來 $horizon最低價格的估計',
        color: const Color(0xFFBF5AF2),
      ),
      _buildCompactMetricCell(
        title: '預估價差',
        value: _formatPriceDifference(data.priceDiff),
        jsonKey: '${prefix}_price_diff',
        subtitle: _priceDiffSubtitle(data.priceDiff),
        color: _priceDifferenceColor(data.priceDiff),
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          modelName,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 3),
        Text(
          '預測目標：未來 $horizon最低價格',
          style: TextStyle(
            fontSize: 11,
            color: Colors.white.withValues(alpha: 0.5),
          ),
        ),
        const SizedBox(height: 7),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 390 ? 2 : 1;
            const spacing = 8.0;
            final cardWidth =
                (constraints.maxWidth - spacing * (columns - 1)) / columns;
            return Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: [
                for (final metric in metrics)
                  SizedBox(width: cardWidth, child: metric),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _buildCoinHeading(String coin) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: const Color(0xFF64D2FF).withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: const Color(0xFF64D2FF).withValues(alpha: 0.3),
            ),
          ),
          child: Text(
            coin,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: Color(0xFF64D2FF),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(child: Divider(color: Colors.white.withValues(alpha: 0.08))),
      ],
    );
  }

  Widget _buildModelInfoPanel({
    required String title,
    required String description,
    required Map<String, String> items,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF2997FF).withValues(alpha: 0.055),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: const Color(0xFF2997FF).withValues(alpha: 0.22),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.model_training_rounded,
                size: 18,
                color: Color(0xFF64D2FF),
              ),
              const SizedBox(width: 7),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            description,
            style: TextStyle(
              fontSize: 12,
              height: 1.55,
              color: Colors.white.withValues(alpha: 0.72),
            ),
          ),
          const SizedBox(height: 10),
          for (final entry in items.entries) ...[
            _buildModelInfoRow(entry.key, entry.value),
            if (entry.key != items.keys.last) const SizedBox(height: 6),
          ],
        ],
      ),
    );
  }

  Widget _buildModelInfoRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 108,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: Colors.white.withValues(alpha: 0.42),
            ),
          ),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: TextStyle(
              fontSize: 11,
              height: 1.45,
              color: Colors.white.withValues(alpha: 0.72),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDisclaimerPanel() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.025),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline_rounded,
            size: 18,
            color: Colors.white.withValues(alpha: 0.45),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              '聲明：本系統依歷史市場資料與模型輸出提供研究資訊，僅供專題展示。'
              '穩定幣分類模型的標籤與預測範圍依模型而異，畫面數值為未校準的風險分數，'
              '不是事件發生機率。即時狀態監測與未來風險預警屬於不同任務，不直接合併。'
              '所有價格估計、風險分數與預測方向皆可能失準，不構成投資建議、交易邀約或'
              '收益保證。',
              style: TextStyle(
                fontSize: 11,
                height: 1.55,
                color: Colors.white.withValues(alpha: 0.45),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState({
    required IconData icon,
    required String title,
    required String message,
  }) {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Colors.white.withValues(alpha: 0.3)),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: Colors.white.withValues(alpha: 0.72),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                height: 1.6,
                color: Colors.white.withValues(alpha: 0.4),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 精簡數據卡片。
  /// 每個指標都有獨立背景與框線，完整說明及 JSON 欄位可由滑鼠提示查看。
  Widget _buildCompactMetricCell({
    required String title,
    required String value,
    required String jsonKey,
    required String subtitle,
    required Color color,
  }) {
    return Tooltip(
      message: '$title\n$subtitle\n$jsonKey',
      waitDuration: const Duration(milliseconds: 300),
      child: Container(
        height: 76,
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.055),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.28)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Colors.white.withValues(alpha: 0.58),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 7),
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    value,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: color,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorPanel() {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 560),
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.redAccent.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.redAccent.withValues(alpha: 0.35)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline_rounded,
              size: 42,
              color: Colors.redAccent,
            ),
            const SizedBox(height: 16),
            SelectableText(
              errorMessage!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.redAccent, height: 1.5),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: canLoadStablecoinData ? _loadStablecoinRisk : null,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重試'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWarningBanner(String message) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.orangeAccent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.orangeAccent.withValues(alpha: 0.25)),
      ),
      child: Text(
        '更新失敗，目前顯示上一次資料：$message',
        style: const TextStyle(fontSize: 12, color: Colors.orangeAccent),
      ),
    );
  }

  // ==========================================================
  // 7. 左側分類與複選選單
  // ==========================================================

  Widget _buildHoverCategoryMenu({
    required String category,
    required String subtitle,
    required List<String> coins,
    required bool showModels,
  }) {
    final isHovered = hoveredCategory == category;
    final isOpen = isHovered || expandedCategory == category;
    final hasSelection = _hasSelectedCategory(category);
    final canSelectModels = category == '穩定幣' && hasSelectedStablecoin;

    return MouseRegion(
      onEnter: (_) {
        setState(() {
          hoveredCategory = category;
        });
      },
      onExit: (_) {
        setState(() {
          hoveredCategory = null;
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        decoration: BoxDecoration(
          color: isHovered || hasSelection
              ? const Color(0xFF242426)
              : const Color(0xFF1D1D1F),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: hasSelection
                ? const Color(0xFF2997FF).withValues(alpha: 0.7)
                : Colors.white.withValues(alpha: isHovered ? 0.16 : 0.08),
          ),
        ),
        child: Column(
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () {
                setState(() {
                  expandedCategory = expandedCategory == category
                      ? null
                      : category;
                });
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 15,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            category,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            subtitle,
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.white.withValues(alpha: 0.48),
                            ),
                          ),
                        ],
                      ),
                    ),
                    AnimatedRotation(
                      turns: isOpen ? 0.5 : 0,
                      duration: const Duration(milliseconds: 180),
                      child: Icon(
                        Icons.keyboard_arrow_down_rounded,
                        color: Colors.white.withValues(alpha: 0.65),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              child: isOpen
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildSectionTitle('幣種（可複選）'),
                          const SizedBox(height: 8),
                          ...coins.map(
                            (coin) => _buildMenuOption(
                              text: coin,
                              isSelected:
                                  selectedCategory == category &&
                                  selectedCoins.contains(coin),
                              onTap: () => _toggleCoin(category, coin),
                            ),
                          ),
                          if (showModels) ...[
                            const SizedBox(height: 14),
                            _buildSectionTitle(
                              canSelectModels
                                  ? '分類模型（可複選）'
                                  : '分類模型（請先至少選一個穩定幣）',
                            ),
                            const SizedBox(height: 8),
                            ...models.map(
                              (model) => _buildMenuOption(
                                text: _displayModelName(model),
                                isSelected: selectedModels.contains(model),
                                enabled: canSelectModels,
                                onTap: () => _toggleModel(model),
                              ),
                            ),
                          ],
                        ],
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: Colors.white.withValues(alpha: 0.5),
        ),
      ),
    );
  }

  Widget _buildMenuOption({
    required String text,
    required bool isSelected,
    required VoidCallback onTap,
    bool enabled = true,
  }) {
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: enabled ? onTap : null,
        child: Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          decoration: BoxDecoration(
            color: isSelected
                ? const Color(0xFF2997FF).withValues(alpha: 0.18)
                : Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isSelected
                  ? const Color(0xFF2997FF).withValues(alpha: 0.75)
                  : Colors.white.withValues(alpha: 0.06),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  text,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
              Icon(
                isSelected
                    ? Icons.check_circle_rounded
                    : Icons.add_circle_outline_rounded,
                size: 18,
                color: isSelected
                    ? const Color(0xFF2997FF)
                    : Colors.white.withValues(alpha: 0.38),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSelectedSummary() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF242426),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '目前選擇',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Colors.white.withValues(alpha: 0.58),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            selectedCategory ?? '-',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
          if (selectedCoins.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              '幣種：${selectedCoins.join(', ')}',
              style: TextStyle(
                fontSize: 13,
                color: Colors.white.withValues(alpha: 0.72),
              ),
            ),
          ],
          if (isStableCoinCategory && selectedModels.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              '模型：${selectedModels.map(_displayModelName).join(', ')}',
              style: TextStyle(
                fontSize: 13,
                color: Colors.white.withValues(alpha: 0.72),
              ),
            ),
          ],
          const SizedBox(height: 12),
          TextButton(
            onPressed: _clearSelection,
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 32),
            ),
            child: const Text('清除選擇'),
          ),
        ],
      ),
    );
  }

  // ==========================================================
  // 8. 數字格式與風險色彩
  // ==========================================================

  String _formatUsd(double value) {
    return '\$${value.toStringAsFixed(6)}';
  }

  String _formatRiskScore(double score) {
    return '${score.toStringAsFixed(2)} / 100';
  }

  String _formatCryptoPrice(double value) {
    return '\$${_formatKlineNumber(value)}';
  }

  String _formatKlineNumber(double value) {
    final absolute = value.abs();
    if (absolute >= 1000) return value.toStringAsFixed(2);
    if (absolute >= 1) return value.toStringAsFixed(4);
    return value.toStringAsFixed(6);
  }

  String _formatVolume(double value) {
    final absolute = value.abs();
    if (absolute >= 1000000000) {
      return '${(value / 1000000000).toStringAsFixed(2)}B';
    }
    if (absolute >= 1000000) {
      return '${(value / 1000000).toStringAsFixed(2)}M';
    }
    if (absolute >= 1000) {
      return '${(value / 1000).toStringAsFixed(2)}K';
    }
    return value.toStringAsFixed(2);
  }

  String _formatPercent(double value) {
    return '${value.toStringAsFixed(2)}%';
  }

  String _formatSignedPercentPoints(double value) {
    final sign = value > 0 ? '+' : '';
    return '$sign${value.toStringAsFixed(2)} 個百分點';
  }

  String _formatPriceDifference(double value) {
    if (value > 0) {
      return '+\$${value.toStringAsFixed(6)}';
    }

    if (value < 0) {
      return '-\$${value.abs().toStringAsFixed(6)}';
    }

    return '\$0.000000';
  }

  String _priceDiffSubtitle(double value) {
    if (value > 0) return '後端回傳的價格差為正值';
    if (value < 0) return '後端回傳的價格差為負值';
    return '後端回傳的價格差為零';
  }

  String _formatTime(DateTime time) {
    String twoDigits(int number) => number.toString().padLeft(2, '0');

    return '${time.year}-'
        '${twoDigits(time.month)}-'
        '${twoDigits(time.day)} '
        '${twoDigits(time.hour)}:'
        '${twoDigits(time.minute)}:'
        '${twoDigits(time.second)}';
  }

  Color _priceDifferenceColor(double difference) {
    if (difference > 0) return const Color(0xFF30D158);
    if (difference < 0) return const Color(0xFFFF453A);
    return const Color(0xFF64D2FF);
  }

  Color _riskScoreColor(double score) {
    if (score >= 70) return const Color(0xFFFF453A);
    if (score >= 50) return const Color(0xFFFFD60A);
    return const Color(0xFF30D158);
  }

  String _displayRiskLevel(String riskLevel) {
    final normalized = riskLevel.trim().toLowerCase();
    if (normalized.contains('high') ||
        normalized.contains('danger') ||
        normalized.contains('嚴重') ||
        normalized.contains('高')) {
      return '高風險';
    }
    if (normalized.contains('medium') ||
        normalized.contains('moderate') ||
        normalized.contains('預警') ||
        normalized.contains('中')) {
      return '風險預警';
    }
    if (normalized.contains('low') ||
        normalized.contains('safe') ||
        normalized.contains('安全') ||
        normalized.contains('低')) {
      return '低風險';
    }
    return riskLevel;
  }

  Color _trendColor(String trendLabel) {
    final normalized = trendLabel.trim().toLowerCase();
    if (normalized.contains('up') ||
        normalized.contains('bull') ||
        normalized.contains('上漲')) {
      return const Color(0xFF30D158);
    }
    return const Color(0xFFFF453A);
  }

  /// 優先依後端 risk_level 文字上色；無法辨識時才參考風險分數。
  Color _riskLevelColor(String riskLevel, double riskScore) {
    final normalized = riskLevel.trim().toLowerCase();

    if (normalized.contains('high') ||
        normalized.contains('danger') ||
        normalized.contains('高')) {
      return const Color(0xFFFF453A);
    }

    if (normalized.contains('medium') ||
        normalized.contains('moderate') ||
        normalized.contains('中')) {
      return const Color(0xFFFFD60A);
    }

    if (normalized.contains('low') ||
        normalized.contains('safe') ||
        normalized.contains('低')) {
      return const Color(0xFF30D158);
    }

    return _riskScoreColor(riskScore);
  }
}

/// 支援查看、鎖定、平移與縮放的互動式 K 線圖。
class InteractiveCandlestickChart extends StatefulWidget {
  final List<CandlestickData> candles;
  final bool mobileMode;
  final ValueChanged<CandlestickData?>? onInspectionChanged;

  const InteractiveCandlestickChart({
    super.key,
    required this.candles,
    required this.mobileMode,
    this.onInspectionChanged,
  });

  @override
  State<InteractiveCandlestickChart> createState() =>
      _InteractiveCandlestickChartState();
}

class _InteractiveCandlestickChartState
    extends State<InteractiveCandlestickChart> {
  int? _inspectedOriginalIndex;
  bool _inspectionLocked = false;
  Offset? _crosshairPosition;
  int _windowOffset = 0;
  int? _zoomVisibleCount;
  double _dragAccumulator = 0;
  bool _isDragging = false;

  @override
  void didUpdateWidget(covariant InteractiveCandlestickChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.candles, widget.candles) ||
        oldWidget.mobileMode != widget.mobileMode) {
      _inspectedOriginalIndex = null;
      _inspectionLocked = false;
      _crosshairPosition = null;
      _windowOffset = 0;
      _zoomVisibleCount = null;
      _dragAccumulator = 0;
    }
  }

  double _rightAxisWidth() => widget.mobileMode ? 58.0 : 76.0;

  int _visibleCount(Size size) {
    const chartLeft = 6.0;
    final chartRight = math.max(chartLeft + 20, size.width - _rightAxisWidth());
    final chartWidth = chartRight - chartLeft;
    final widthBasedCount = math.max(8, (chartWidth / 15).floor());
    final defaultCount = widget.mobileMode ? 20 : math.min(55, widthBasedCount);
    final targetCount = _zoomVisibleCount ?? defaultCount;
    return math.min(widget.candles.length, targetCount);
  }

  int _maximumWindowOffset(Size size) {
    return math.max(0, widget.candles.length - _visibleCount(size));
  }

  int? _indexAt(Offset localPosition, Size size) {
    if (widget.candles.isEmpty || size.width < 120 || size.height < 90) {
      return null;
    }

    const chartLeft = 6.0;
    final rightAxisWidth = _rightAxisWidth();
    final chartRight = math.max(chartLeft + 20, size.width - rightAxisWidth);
    final chartWidth = chartRight - chartLeft;

    // 滑鼠位於價格刻度區之外時，不顯示 hover。
    if (localPosition.dx < chartLeft || localPosition.dx > chartRight) {
      return null;
    }

    final visibleCount = _visibleCount(size);

    if (visibleCount <= 0) return null;

    final slotWidth = chartWidth / visibleCount;
    final visibleIndex = ((localPosition.dx - chartLeft) / slotWidth)
        .floor()
        .clamp(0, visibleCount - 1);
    final clampedOffset = _windowOffset.clamp(0, _maximumWindowOffset(size));
    final windowEndIndex = widget.candles.length - clampedOffset;
    final firstOriginalIndex = windowEndIndex - visibleCount;
    return firstOriginalIndex + visibleIndex;
  }

  void _inspectAt(
    Offset localPosition,
    Size size, {
    required bool lockSelection,
  }) {
    if (_inspectionLocked && !lockSelection) return;
    final originalIndex = _indexAt(localPosition, size);
    if (originalIndex == null) {
      if (!lockSelection) _clearInspection();
      return;
    }

    if (lockSelection &&
        _inspectionLocked &&
        _inspectedOriginalIndex == originalIndex) {
      _clearInspection();
      return;
    }

    final changedIndex = _inspectedOriginalIndex != originalIndex;
    setState(() {
      _inspectedOriginalIndex = originalIndex;
      _inspectionLocked = lockSelection;
      _crosshairPosition = localPosition;
    });
    if (changedIndex || lockSelection) {
      widget.onInspectionChanged?.call(widget.candles[originalIndex]);
    }
  }

  void _clearInspection() {
    if (_inspectedOriginalIndex == null && _crosshairPosition == null) return;
    setState(() {
      _inspectedOriginalIndex = null;
      _inspectionLocked = false;
      _crosshairPosition = null;
    });
    widget.onInspectionChanged?.call(null);
  }

  void _handleHorizontalDrag(double horizontalDelta, Size size) {
    if (widget.candles.isEmpty) return;
    const chartLeft = 6.0;
    final chartRight = math.max(chartLeft + 20, size.width - _rightAxisWidth());
    final visibleCount = _visibleCount(size);
    if (visibleCount <= 0) return;

    final slotWidth = (chartRight - chartLeft) / visibleCount;
    _dragAccumulator += horizontalDelta;
    final candleSteps = (_dragAccumulator / slotWidth).truncate();
    if (candleSteps == 0) return;

    _dragAccumulator -= candleSteps * slotWidth;
    final nextOffset = (_windowOffset + candleSteps).clamp(
      0,
      _maximumWindowOffset(size),
    );
    if (nextOffset == _windowOffset) return;

    setState(() {
      _windowOffset = nextOffset;
      _inspectedOriginalIndex = null;
      _inspectionLocked = false;
      _crosshairPosition = null;
    });
    widget.onInspectionChanged?.call(null);
  }

  void _setVisibleCount(int count, Size size) {
    if (widget.candles.isEmpty) return;
    final minimum = math.min(8, widget.candles.length);
    final next = count.clamp(minimum, widget.candles.length);
    if (next == _visibleCount(size)) return;
    setState(() {
      _zoomVisibleCount = next;
      _windowOffset = _windowOffset.clamp(
        0,
        math.max(0, widget.candles.length - next),
      );
      _inspectedOriginalIndex = null;
      _inspectionLocked = false;
      _crosshairPosition = null;
    });
    widget.onInspectionChanged?.call(null);
  }

  void _zoomBy(int candleDelta, Size size) {
    _setVisibleCount(_visibleCount(size) + candleDelta, size);
  }

  void _moveWindowBy(int candleDelta, Size size) {
    final nextOffset = (_windowOffset + candleDelta).clamp(
      0,
      _maximumWindowOffset(size),
    );
    if (nextOffset == _windowOffset) return;
    setState(() {
      _windowOffset = nextOffset;
      _inspectedOriginalIndex = null;
      _inspectionLocked = false;
      _crosshairPosition = null;
    });
    widget.onInspectionChanged?.call(null);
  }

  void _resetView() {
    setState(() {
      _windowOffset = 0;
      _zoomVisibleCount = null;
      _inspectedOriginalIndex = null;
      _inspectionLocked = false;
      _crosshairPosition = null;
      _dragAccumulator = 0;
    });
    widget.onInspectionChanged?.call(null);
  }

  Widget _chartControls(Size size) {
    const buttonConstraints = BoxConstraints.tightFor(width: 32, height: 32);

    return Align(
      alignment: Alignment.centerLeft,
      child: Material(
        color: const Color(0xE61C1C1F),
        borderRadius: BorderRadius.circular(6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: '放大 K 線',
              constraints: buttonConstraints,
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              onPressed: () => _zoomBy(-5, size),
              icon: const Icon(Icons.add, size: 17),
            ),
            IconButton(
              tooltip: '縮小 K 線',
              constraints: buttonConstraints,
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              onPressed: () => _zoomBy(5, size),
              icon: const Icon(Icons.remove, size: 17),
            ),
            IconButton(
              tooltip: '查看較早 K 線',
              constraints: buttonConstraints,
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              onPressed: _windowOffset < _maximumWindowOffset(size)
                  ? () => _moveWindowBy(
                      math.max(1, _visibleCount(size) ~/ 3),
                      size,
                    )
                  : null,
              icon: const Icon(Icons.chevron_left_rounded, size: 19),
            ),
            IconButton(
              tooltip: '查看較新 K 線',
              constraints: buttonConstraints,
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              onPressed: _windowOffset > 0
                  ? () => _moveWindowBy(
                      -math.max(1, _visibleCount(size) ~/ 3),
                      size,
                    )
                  : null,
              icon: const Icon(Icons.chevron_right_rounded, size: 19),
            ),
            if (_windowOffset > 0 || _zoomVisibleCount != null)
              TextButton.icon(
                onPressed: _resetView,
                icon: const Icon(Icons.last_page_rounded, size: 17),
                label: const Text('回最新'),
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 32),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  visualDensity: VisualDensity.compact,
                  foregroundColor: const Color(0xFF64D2FF),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const toolbarHeight = 40.0;
        final size = Size(
          constraints.maxWidth,
          math.max(90.0, constraints.maxHeight - toolbarHeight),
        );
        final visibleCount = _visibleCount(size);

        final chart = CustomPaint(
          painter: CandlestickChartPainter(
            candles: widget.candles,
            inspectedOriginalIndex: _inspectedOriginalIndex,
            inspectionLocked: _inspectionLocked,
            crosshairPosition: _crosshairPosition,
            mobileMode: widget.mobileMode,
            windowOffset: _windowOffset,
            visibleCount: visibleCount,
          ),
          child: const SizedBox.expand(),
        );

        final gestures = Listener(
          onPointerSignal: (event) {
            if (event is PointerScrollEvent) {
              _zoomBy(event.scrollDelta.dy > 0 ? 5 : -5, size);
            }
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (details) =>
                _inspectAt(details.localPosition, size, lockSelection: true),
            onHorizontalDragStart: (_) {
              _dragAccumulator = 0;
              _isDragging = true;
            },
            onHorizontalDragUpdate: (details) =>
                _handleHorizontalDrag(details.delta.dx, size),
            onHorizontalDragEnd: (_) => _isDragging = false,
            onHorizontalDragCancel: () => _isDragging = false,
            child: chart,
          ),
        );

        return Column(
          children: [
            SizedBox(height: toolbarHeight, child: _chartControls(size)),
            Expanded(
              child: MouseRegion(
                cursor: SystemMouseCursors.precise,
                onHover: (event) {
                  if (!_isDragging) {
                    _inspectAt(event.localPosition, size, lockSelection: false);
                  }
                },
                onExit: (_) {
                  if (!_inspectionLocked) _clearInspection();
                },
                child: gestures,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 不依賴第三方圖表套件的 K 線與成交量繪圖器。
class CandlestickChartPainter extends CustomPainter {
  final List<CandlestickData> candles;
  final int? inspectedOriginalIndex;
  final bool inspectionLocked;
  final Offset? crosshairPosition;
  final bool mobileMode;
  final int windowOffset;
  final int visibleCount;

  const CandlestickChartPainter({
    required this.candles,
    this.inspectedOriginalIndex,
    required this.inspectionLocked,
    this.crosshairPosition,
    required this.mobileMode,
    required this.windowOffset,
    required this.visibleCount,
  });

  static const Color _upColor = Color(0xFFFF453A);
  static const Color _downColor = Color(0xFF30D158);
  static const Color _axisTextColor = Color(0xFF85858A);
  static const Color _gridColor = Color(0xFF29292D);

  @override
  void paint(Canvas canvas, Size size) {
    if (candles.isEmpty || size.width < 120 || size.height < 90) return;

    const chartLeft = 6.0;
    final rightAxisWidth = mobileMode ? 58.0 : 76.0;
    const bottomAxisHeight = 28.0;
    const priceVolumeGap = 10.0;

    final chartRight = math.max(chartLeft + 20, size.width - rightAxisWidth);
    final chartWidth = chartRight - chartLeft;
    const chartTop = 6.0;
    final chartBottom = size.height - bottomAxisHeight;
    final availableHeight = chartBottom - chartTop;
    final volumeHeight = math.max(42.0, availableHeight * 0.24);
    final volumeTop = chartBottom - volumeHeight;
    final priceBottom = volumeTop - priceVolumeGap;
    final priceHeight = priceBottom - chartTop;

    if (priceHeight <= 20) return;

    final maximumWindowOffset = math.max(0, candles.length - visibleCount);
    final clampedWindowOffset = windowOffset.clamp(0, maximumWindowOffset);
    final windowEndIndex = candles.length - clampedWindowOffset;
    final firstVisibleOriginalIndex = windowEndIndex - visibleCount;
    final visible = candles.sublist(firstVisibleOriginalIndex, windowEndIndex);

    final int? inspectedVisibleIndex =
        inspectedOriginalIndex != null &&
            inspectedOriginalIndex! >= firstVisibleOriginalIndex &&
            inspectedOriginalIndex! < windowEndIndex
        ? inspectedOriginalIndex! - firstVisibleOriginalIndex
        : null;

    var minimumPrice = visible.first.low;
    var maximumPrice = visible.first.high;
    var maximumVolume = visible.first.volume;

    for (final candle in visible.skip(1)) {
      minimumPrice = math.min(minimumPrice, candle.low);
      maximumPrice = math.max(maximumPrice, candle.high);
      maximumVolume = math.max(maximumVolume, candle.volume);
    }

    var priceRange = maximumPrice - minimumPrice;
    if (priceRange == 0) {
      priceRange = math.max(maximumPrice.abs() * 0.01, 0.000001);
    }
    final pricePadding = priceRange * 0.08;
    minimumPrice -= pricePadding;
    maximumPrice += pricePadding;
    priceRange = maximumPrice - minimumPrice;

    double priceY(double price) {
      return chartTop +
          ((maximumPrice - price) / priceRange).clamp(0.0, 1.0).toDouble() *
              priceHeight;
    }

    final gridPaint = Paint()
      ..color = _gridColor
      ..strokeWidth = 1;

    const horizontalGridCount = 4;
    for (var index = 0; index <= horizontalGridCount; index++) {
      final ratio = index / horizontalGridCount;
      final y = chartTop + priceHeight * ratio;
      canvas.drawLine(Offset(chartLeft, y), Offset(chartRight, y), gridPaint);

      final value = maximumPrice - priceRange * ratio;
      _drawText(
        canvas,
        _formatAxisPrice(value, priceRange),
        Offset(chartRight + 6, y - 7),
        color: _axisTextColor,
        fontSize: mobileMode ? 10 : 12,
      );
    }

    canvas.drawLine(
      Offset(chartLeft, volumeTop),
      Offset(chartRight, volumeTop),
      gridPaint,
    );

    _drawText(
      canvas,
      '成交量',
      Offset(chartLeft, volumeTop + 3),
      color: _axisTextColor,
      fontSize: 11,
    );

    final slotWidth = chartWidth / visible.length;
    final bodyWidth = (slotWidth * 0.68).clamp(3.0, 12.0).toDouble();
    final candleClip = Rect.fromLTRB(
      chartLeft,
      chartTop,
      chartRight,
      chartBottom,
    );

    canvas.save();
    canvas.clipRect(candleClip);

    for (var index = 0; index < visible.length; index++) {
      final candle = visible[index];
      final isUp = candle.close >= candle.open;
      final color = isUp ? _upColor : _downColor;
      final centerX = chartLeft + slotWidth * (index + 0.5);

      final wickPaint = Paint()
        ..color = color
        ..strokeWidth = math.max(1.2, bodyWidth * 0.13);
      canvas.drawLine(
        Offset(centerX, priceY(candle.high)),
        Offset(centerX, priceY(candle.low)),
        wickPaint,
      );

      final openY = priceY(candle.open);
      final closeY = priceY(candle.close);
      final bodyTop = math.min(openY, closeY);
      final bodyHeight = math.max((openY - closeY).abs(), 2.0);
      canvas.drawRect(
        Rect.fromLTWH(
          centerX - bodyWidth / 2,
          bodyTop - (bodyHeight == 2.0 ? 1.0 : 0),
          bodyWidth,
          bodyHeight,
        ),
        Paint()..color = color,
      );

      if (maximumVolume > 0 && candle.volume > 0) {
        final normalizedVolume = (candle.volume / maximumVolume)
            .clamp(0.0, 1.0)
            .toDouble();
        final barHeight = normalizedVolume * (volumeHeight - 14);
        canvas.drawRect(
          Rect.fromLTWH(
            centerX - bodyWidth / 2,
            chartBottom - barHeight,
            bodyWidth,
            barHeight,
          ),
          Paint()..color = color.withValues(alpha: 0.42),
        );
      }
    }

    final latestCloseY = priceY(visible.last.close);
    _drawDashedLine(
      canvas,
      Offset(chartLeft, latestCloseY),
      Offset(chartRight, latestCloseY),
      Paint()
        ..color =
            (visible.last.close >= visible.last.open ? _upColor : _downColor)
                .withValues(alpha: 0.55)
        ..strokeWidth = 1,
    );

    // 滑鼠或觸控選取 K 棒時顯示垂直、水平十字線。
    if (inspectedVisibleIndex != null) {
      final hoverX = chartLeft + slotWidth * (inspectedVisibleIndex + 0.5);
      final crosshairColor = Colors.white.withValues(
        alpha: inspectionLocked ? 0.72 : 0.46,
      );
      canvas.drawLine(
        Offset(hoverX, chartTop),
        Offset(hoverX, chartBottom),
        Paint()
          ..color = crosshairColor
          ..strokeWidth = 1,
      );

      final pointerY = crosshairPosition?.dy;
      if (pointerY != null && pointerY >= chartTop && pointerY <= priceBottom) {
        canvas.drawLine(
          Offset(chartLeft, pointerY),
          Offset(chartRight, pointerY),
          Paint()
            ..color = crosshairColor
            ..strokeWidth = 1,
        );

        final ratio = ((pointerY - chartTop) / priceHeight)
            .clamp(0.0, 1.0)
            .toDouble();
        final crosshairPrice = maximumPrice - priceRange * ratio;
        _drawAxisTag(
          canvas,
          text: _formatAxisPrice(crosshairPrice, priceRange),
          x: chartRight + 2,
          centerY: pointerY,
          background: const Color(0xFF4A4A4F),
          maximumWidth: rightAxisWidth - 2,
        );
      }
    }

    canvas.restore();

    final timeIndices = <int>{0, visible.length ~/ 2, visible.length - 1};
    for (final index in timeIndices) {
      final centerX = chartLeft + slotWidth * (index + 0.5);
      final label = _formatTimeLabel(visible[index].time);
      final painter = _textPainter(
        label,
        color: _axisTextColor,
        fontSize: mobileMode ? 9 : 11,
      );
      final maximumX = math.max(chartLeft, chartRight - painter.width);
      final x = (centerX - painter.width / 2)
          .clamp(chartLeft, maximumX)
          .toDouble();
      painter.paint(canvas, Offset(x, chartBottom + 6));
    }

    // Hover 時在時間軸上顯示精確時間，並以深色標籤突顯。
    if (inspectedVisibleIndex != null) {
      final inspected = visible[inspectedVisibleIndex];
      final hoverX = chartLeft + slotWidth * (inspectedVisibleIndex + 0.5);
      final label = _formatFullTimeLabel(inspected.time);
      final painter = _textPainter(label, color: Colors.white, fontSize: 12);

      const horizontalPadding = 7.0;
      const verticalPadding = 4.0;
      final boxWidth = painter.width + horizontalPadding * 2;
      final boxHeight = painter.height + verticalPadding * 2;
      final maximumX = math.max(chartLeft, chartRight - boxWidth);
      final boxX = (hoverX - boxWidth / 2)
          .clamp(chartLeft, maximumX)
          .toDouble();
      final boxY = math.max(chartBottom + 2, size.height - boxHeight - 1);
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(boxX, boxY, boxWidth, boxHeight),
        const Radius.circular(5),
      );

      canvas.drawRRect(rect, Paint()..color = const Color(0xFF2C2C2E));
      painter.paint(
        canvas,
        Offset(boxX + horizontalPadding, boxY + verticalPadding),
      );
    }

    _drawAxisTag(
      canvas,
      text: _formatAxisPrice(visible.last.close, priceRange),
      x: chartRight + 2,
      centerY: latestCloseY,
      background: visible.last.close >= visible.last.open
          ? _upColor
          : _downColor,
      maximumWidth: rightAxisWidth - 2,
    );
  }

  static void _drawAxisTag(
    Canvas canvas, {
    required String text,
    required double x,
    required double centerY,
    required Color background,
    required double maximumWidth,
  }) {
    final painter = _textPainter(text, color: Colors.white, fontSize: 10);
    const verticalPadding = 3.0;
    const horizontalPadding = 4.0;
    final width = math.min(maximumWidth, painter.width + horizontalPadding * 2);
    final height = painter.height + verticalPadding * 2;
    final top = centerY - height / 2;
    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(x, top, width, height),
      const Radius.circular(3),
    );
    canvas.drawRRect(rect, Paint()..color = background);
    painter.paint(canvas, Offset(x + horizontalPadding, top + verticalPadding));
  }

  static String _formatAxisPrice(double value, double range) {
    if (value.abs() >= 1000) return value.toStringAsFixed(2);
    if (range < 0.01) return value.toStringAsFixed(6);
    if (range < 1) return value.toStringAsFixed(4);
    return value.toStringAsFixed(2);
  }

  static String _formatTimeLabel(DateTime value) {
    String twoDigits(int number) => number.toString().padLeft(2, '0');
    return '${twoDigits(value.month)}/${twoDigits(value.day)} '
        '${twoDigits(value.hour)}:${twoDigits(value.minute)}';
  }

  static String _formatFullTimeLabel(DateTime value) {
    String twoDigits(int number) => number.toString().padLeft(2, '0');
    return '${value.year}-${twoDigits(value.month)}-${twoDigits(value.day)} '
        '${twoDigits(value.hour)}:${twoDigits(value.minute)}:${twoDigits(value.second)}';
  }

  static TextPainter _textPainter(
    String text, {
    required Color color,
    required double fontSize,
  }) {
    return TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: color, fontSize: fontSize),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
  }

  static void _drawText(
    Canvas canvas,
    String text,
    Offset offset, {
    required Color color,
    required double fontSize,
  }) {
    _textPainter(text, color: color, fontSize: fontSize).paint(canvas, offset);
  }

  static void _drawDashedLine(
    Canvas canvas,
    Offset start,
    Offset end,
    Paint paint,
  ) {
    const dashWidth = 4.0;
    const dashSpace = 3.0;
    var x = start.dx;

    while (x < end.dx) {
      canvas.drawLine(
        Offset(x, start.dy),
        Offset(math.min(x + dashWidth, end.dx), end.dy),
        paint,
      );
      x += dashWidth + dashSpace;
    }
  }

  @override
  bool shouldRepaint(CandlestickChartPainter oldDelegate) {
    return oldDelegate.candles != candles ||
        oldDelegate.inspectedOriginalIndex != inspectedOriginalIndex ||
        oldDelegate.inspectionLocked != inspectionLocked ||
        oldDelegate.crosshairPosition != crosshairPosition ||
        oldDelegate.mobileMode != mobileMode ||
        oldDelegate.windowOffset != windowOffset ||
        oldDelegate.visibleCount != visibleCount;
  }
}
