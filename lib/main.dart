import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

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

/// USDC 或 TUSD 的單一預測模型五項資料。
class StablecoinModelMetrics {
  final double currentPrice;
  final double future6hLow;
  final double priceDiff;
  final double depegProbability;
  final String riskLevel;

  const StablecoinModelMetrics({
    required this.currentPrice,
    required this.future6hLow,
    required this.priceDiff,
    required this.depegProbability,
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
      depegProbability: _readProbability(
        payload,
        '${prefix}_depeg_probability',
      ),
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

  /// 後端的 depeg_probability 已經是百分比數值。
  ///
  /// 例如後端回傳 25 或 "25%"，前端都保留為 25。
  static double _readProbability(Map<String, dynamic> json, String key) {
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
// 2. API 服務
// ============================================================

/// 同時載入摘要與 K 線時共用正在進行的 overview 請求。
/// 完成後不快取，下次按重新抓取仍會向後端取得新資料。
class DashboardOverviewApi {
  static Future<Map<String, dynamic>>? _inFlight;

  static Future<Map<String, dynamic>> fetchData() async {
    final pending = _inFlight ??= _fetchData();
    try {
      return await pending;
    } finally {
      if (identical(_inFlight, pending)) _inFlight = null;
    }
  }

  static Future<Map<String, dynamic>> _fetchData() async {
    if (StablecoinRiskApi.baseUrl.trim().isEmpty) {
      throw StateError('請使用 --dart-define=API_BASE_URL 設定後端網址');
    }
    final uri = Uri.parse(
      '${StablecoinRiskApi.baseUrl}${StablecoinRiskApi.riskPath}',
    );
    final response = await http
        .get(uri, headers: const {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('API 呼叫失敗：HTTP ${response.statusCode}');
    }
    final dynamic decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map) {
      throw const FormatException('API 回傳的 JSON 根節點必須是物件');
    }
    final root = Map<String, dynamic>.from(decoded);
    if (root['success'] == false) {
      throw Exception(root['message'] ?? root['error'] ?? '後端回報資料取得失敗');
    }
    if (root['data'] is Map) {
      final data = Map<String, dynamic>.from(root['data'] as Map);
      // 保留後端回應時間，用同一個資料快照判斷 K 棒是否已收盤。
      // 不使用畫面重繪時間，以免舊資料跨小時後被誤認為新收盤資料。
      data['_overview_timestamp'] = root['timestamp'];
      return data;
    }
    // 保留舊版直接回傳資料的包裝格式。
    return root;
  }
}

class StablecoinRiskApi {
  static const String baseUrl = String.fromEnvironment('API_BASE_URL');
  static const String riskPath = '/api/v1/dashboard/overview';

  static Future<Map<String, dynamic>> fetchPayload() async {
    final data = await DashboardOverviewApi.fetchData();
    if (data['stablecoins'] is Map) {
      return Map<String, dynamic>.from(data['stablecoins'] as Map);
    }
    return data;
  }
}

// ============================================================
// 2-1. 一般加密貨幣（BTC / ETH / SOL / XRP）趨勢資料
// ============================================================

/// data.cryptos 陣列中的一個幣種。
/// up_score 是後端的上漲分數；不將它改名為上漲機率。
class CryptoOverviewData {
  final String coin;
  final int predictionHorizonHours;
  final double upScore;
  final String trendLabel;
  final double displayThreshold;
  final String klineInterval;
  final List<CandlestickData> candles;
  final DateTime dataAsOf;

  const CryptoOverviewData({
    required this.coin,
    required this.predictionHorizonHours,
    required this.upScore,
    required this.trendLabel,
    required this.displayThreshold,
    required this.klineInterval,
    required this.candles,
    required this.dataAsOf,
  });

  factory CryptoOverviewData.fromPayload(
    Map<String, dynamic> payload, {
    DateTime? dataAsOf,
  }) {
    final hours = _readDouble(payload, 'prediction_horizon_hours');
    if (hours <= 0 || hours != hours.truncateToDouble()) {
      throw const FormatException('prediction_horizon_hours 必須是正整數');
    }
    final score = _readDouble(payload, 'up_score');
    final threshold = _readDouble(payload, 'display_threshold');
    if (score < 0 || score > 100 || threshold < 0 || threshold > 100) {
      throw const FormatException('up_score 與 display_threshold 必須介於 0～100');
    }
    final coin = _readString(payload, 'coin').toUpperCase();
    final rows = payload['kline_data'];
    if (rows is! List) {
      throw FormatException('$coin 缺少 kline_data 陣列');
    }
    return CryptoOverviewData(
      coin: coin,
      predictionHorizonHours: hours.toInt(),
      upScore: score,
      trendLabel: _readString(payload, 'trend_label'),
      displayThreshold: threshold,
      klineInterval: _readString(payload, 'kline_interval'),
      candles: KlineApi.parseCandles(rows, '$coin.kline_data'),
      dataAsOf: dataAsOf ?? DateTime.now(),
    );
  }

  /// JSON time 是 K 棒起始時間，例如 22:00 的 1h K 棒在 23:00 收盤。
  /// 以 API 回應時間為準，找到最近一根完整收盤的 K 棒。
  /// 此值用來推算模型資料截至時間；不是後端獨立提供的模型時間戳。
  CandlestickData? get latestClosedCandle {
    final match = RegExp(r'^(\d+)([mhdw])$').firstMatch(klineInterval);
    if (match == null) return null;
    final count = int.parse(match.group(1)!);
    if (count <= 0) return null;
    final Duration interval;
    switch (match.group(2)!) {
      case 'm':
        interval = Duration(minutes: count);
        break;
      case 'h':
        interval = Duration(hours: count);
        break;
      case 'd':
        interval = Duration(days: count);
        break;
      case 'w':
        interval = Duration(days: count * 7);
        break;
      default:
        return null;
    }
    for (final candle in candles.reversed) {
      if (!candle.time.add(interval).isAfter(dataAsOf)) return candle;
    }
    return null;
  }

  double get scoreDifference => upScore - displayThreshold;

  static double _readDouble(Map<String, dynamic> json, String key) {
    final value = json[key];
    final parsed = value is num
        ? value.toDouble()
        : value is String
            ? double.tryParse(value.trim().replaceAll(',', ''))
            : null;
    if (parsed != null && parsed.isFinite) return parsed;
    throw FormatException('加密貨幣欄位 $key 不是有效數字，收到：$value');
  }

  static String _readString(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('加密貨幣 JSON 缺少有效文字欄位：$key');
    }
    return value.trim();
  }
}

class CryptoOverviewApi {
  /// 新版格式：data.cryptos 是陣列，每個物件帶自己的 kline_data。
  static List<Map<String, dynamic>> readRows(Map<String, dynamic> data) {
    final value = data['cryptos'];
    if (value is! List) {
      throw const FormatException('JSON 的 data.cryptos 必須是陣列');
    }
    return value.map((row) {
      if (row is! Map) {
        throw const FormatException('cryptos 陣列的每一筆資料必須是物件');
      }
      return Map<String, dynamic>.from(row);
    }).toList(growable: false);
  }

  static Map<String, CryptoOverviewData> parseData(Map<String, dynamic> data) {
    final result = <String, CryptoOverviewData>{};
    final timestamp = data['_overview_timestamp'] ?? data['timestamp'];
    final dataAsOf = timestamp is String
        ? DateTime.tryParse(timestamp.trim()) ?? DateTime.now()
        : DateTime.now();
    for (final row in readRows(data)) {
      final item = CryptoOverviewData.fromPayload(row, dataAsOf: dataAsOf);
      if (result.containsKey(item.coin)) {
        throw FormatException('cryptos 出現重複幣種：${item.coin}');
      }
      result[item.coin] = item;
    }
    return result;
  }

  static Future<Map<String, CryptoOverviewData>> fetchPayload() async {
    return parseData(await DashboardOverviewApi.fetchData());
  }
}

// ============================================================
// 2-2. K 線資料與 API 服務
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
    if (value is num && value.isFinite) return value.toDouble();

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

class KlineApi {
  /// 穩定幣：data.stablecoins.<coin>_kline_data。
  /// 加密貨幣：data.cryptos[i].kline_data，以 coin 決定對應幣種。
  static Future<Map<String, List<CandlestickData>>> fetchCandles() async {
    return parseData(await DashboardOverviewApi.fetchData());
  }

  static Map<String, List<CandlestickData>> parseData(Map<String, dynamic> data) {
    final stablecoinPayload = data['stablecoins'] is Map
        ? Map<String, dynamic>.from(data['stablecoins'] as Map)
        : data;
    final result = <String, List<CandlestickData>>{};
    for (final coin in const ['USDC', 'TUSD']) {
      final key = '${coin.toLowerCase()}_kline_data';
      final rows = stablecoinPayload[key];
      if (rows is List) result[coin] = parseCandles(rows, key);
    }
    if (data.containsKey('cryptos')) {
      for (final row in CryptoOverviewApi.readRows(data)) {
        final coin = CryptoOverviewData._readString(row, 'coin').toUpperCase();
        final rows = row['kline_data'];
        if (rows is! List) {
          throw FormatException('$coin 缺少 kline_data 陣列');
        }
        if (result.containsKey(coin)) {
          throw FormatException('K 線出現重複幣種：$coin');
        }
        result[coin] = parseCandles(rows, '$coin.kline_data');
      }
    }
    if (result.isEmpty) {
      throw const FormatException('JSON 找不到任何幣種的 K 線陣列');
    }
    return result;
  }

  static List<CandlestickData> parseCandles(List rows, String jsonKey) {
    final uniqueByTime = <int, CandlestickData>{};
    for (final row in rows) {
      if (row is! Map) {
        throw FormatException('$jsonKey 中的每一筆資料都必須是物件');
      }
      final candle = CandlestickData.fromJson(Map<String, dynamic>.from(row));
      uniqueByTime[candle.time.millisecondsSinceEpoch] = candle;
    }
    // 空陣列顯示尚無資料；不讓單一幣種無 K 線時阻擋其他幣種。
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
  static const String modelEnsemble = 'XGBoost+Transformer';
  static const String modelTransformer0995 = 'Transformer0.995';
  static const String modelTransformer099 = 'Transformer0.99';
  static const String modelXGBoost = 'XGBoost';

  /// 模型顯示名稱對應 JSON 中的模型代稱。
  ///
  /// 最後的完整前綴會由「幣種代稱＋模型代稱」組成，例如：
  /// USDC + ensemble -> usdc_ensemble
  /// TUSD + xgboost -> tusd_xgboost
  static const Map<String, String> modelJsonSuffixes = {
    modelEnsemble: 'ensemble',
    modelTransformer0995: 'transformer_0995',
    modelTransformer099: 'transformer_099',
    modelXGBoost: 'xgboost',
  };

  String? hoveredCategory;
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
  int _klineRequestSerial = 0;

  /// 第一層 key 是幣種，第二層 key 是模型顯示名稱。
  /// 例如：modelRiskData['USDC']?['XGBoost']。
  Map<String, Map<String, StablecoinModelMetrics>> modelRiskData = {};

  /// 以幣種為 key 保存四種加密貨幣的趨勢摘要。
  Map<String, CryptoOverviewData> cryptoOverviewByCoin = {};
  bool isCryptoLoading = false;
  String? cryptoErrorMessage;
  DateTime? cryptoLastUpdatedAt;
  int _cryptoRequestSerial = 0;

  /// 用來忽略較舊的非同步 API 回應。
  int _requestSerial = 0;

  final List<String> cryptoCoins = ['BTC', 'ETH', 'SOL', 'XRP'];
  final List<String> stableCoins = ['USDC', 'TUSD'];

  final List<String> models = const [
    modelEnsemble,
    modelTransformer0995,
    modelTransformer099,
    modelXGBoost,
  ];

  @override
  void initState() {
    super.initState();
    // K 線不在頁面初始化時載入。
    // 選到 USDC/TUSD 或 BTC/ETH/SOL/XRP 後才會抓取並顯示。
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

  /// 目前選取的一般加密貨幣，支援四種幣複選。
  List<String> get selectedCryptos {
    if (!isCryptoCategory) {
      return const [];
    }
    return selectedCoins.where(cryptoCoins.contains).toList(growable: false);
  }

  bool get hasSelectedStablecoin => selectedStablecoins.isNotEmpty;
  bool get hasSelectedCrypto => selectedCryptos.isNotEmpty;

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
    if (isStableCoinCategory) return canLoadStablecoinData;
    if (isCryptoCategory) return hasSelectedCrypto;
    return false;
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

  Future<void> _loadKlineData() async {
    // 目前分類有任何已選幣種時才載入 K 線。
    if (!hasSelectedKlineCoin) return;

    final requestId = ++_klineRequestSerial;

    setState(() {
      isKlineLoading = true;
      klineErrorMessage = null;
    });

    try {
      final result = await KlineApi.fetchCandles();
      if (!mounted || requestId != _klineRequestSerial) return;

      final availableSelected = selectedKlineCoins
          .where((coin) => result[coin]?.isNotEmpty ?? false)
          .toList(growable: false);

      setState(() {
        klineDataByCoin = result;
        if (availableSelected.isNotEmpty &&
            !availableSelected.contains(selectedKlineCoin)) {
          selectedKlineCoin = availableSelected.first;
        }
        klineLastUpdatedAt = DateTime.now();
      });
    } on TimeoutException {
      if (!mounted || requestId != _klineRequestSerial) return;
      setState(() {
        klineErrorMessage = 'K 線 API 連線逾時，請確認後端服務是否正常運作。';
      });
    } on FormatException catch (error) {
      if (!mounted || requestId != _klineRequestSerial) return;
      setState(() {
        klineErrorMessage = 'K 線 JSON 格式錯誤：${error.message}';
      });
    } catch (error) {
      if (!mounted || requestId != _klineRequestSerial) return;
      setState(() {
        klineErrorMessage = 'K 線資料讀取失敗：$error';
      });
    } finally {
      if (mounted && requestId == _klineRequestSerial) {
        setState(() {
          isKlineLoading = false;
        });
      }
    }
  }

  /// 讀取目前所有所選幣種與模型的資料。
  Future<void> _loadStablecoinRisk() async {
    if (!canLoadStablecoinData) {
      return;
    }

    // 保存這次請求的幣種與模型，避免等待期間切換選項造成資料錯置。
    final requestId = ++_requestSerial;
    final requestedCoins = List<String>.from(selectedStablecoins);
    final requestedModels = List<String>.from(selectedModels);

    setState(() {
      isLoading = true;
      errorMessage = null;
    });

    try {
      // USDC 與 TUSD 共用同一個 API 回傳。
      final payload = await StablecoinRiskApi.fetchPayload();
      final parsedData = <String, Map<String, StablecoinModelMetrics>>{};

      // 逐一解析每一個「幣種 × 模型」組合。
      for (final coin in requestedCoins) {
        final coinData = <String, StablecoinModelMetrics>{};

        for (final model in requestedModels) {
          final prefix = _jsonPrefixFor(coin, model);
          coinData[model] = StablecoinModelMetrics.fromPayload(payload, prefix);
        }

        parsedData[coin] = coinData;
      }

      if (!mounted || requestId != _requestSerial) return;

      // 如果幣種或模型在 API 回來前已改變，就忽略舊結果。
      if (!_sameStringList(requestedCoins, selectedStablecoins) ||
          !_sameStringList(requestedModels, selectedModels)) {
        return;
      }

      setState(() {
        modelRiskData = parsedData;
        lastUpdatedAt = DateTime.now();
      });
    } on TimeoutException {
      if (!mounted || requestId != _requestSerial) return;

      setState(() {
        errorMessage = 'API 連線逾時，請確認後端服務是否正常運作。';
      });
    } on FormatException catch (error) {
      if (!mounted || requestId != _requestSerial) return;

      setState(() {
        errorMessage = 'JSON 格式錯誤：${error.message}';
      });
    } catch (error) {
      if (!mounted || requestId != _requestSerial) return;

      setState(() {
        errorMessage = '讀取資料失敗：$error';
      });
    } finally {
      if (mounted && requestId == _requestSerial) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  /// 讀取所有加密貨幣；只在畫面上顯示所選幣種。
  Future<void> _loadCryptoOverview() async {
    if (!hasSelectedCrypto) return;
    final requestId = ++_cryptoRequestSerial;
    final requestedCoins = List<String>.from(selectedCryptos);
    setState(() {
      isCryptoLoading = true;
      cryptoErrorMessage = null;
    });
    try {
      final parsed = await CryptoOverviewApi.fetchPayload();
      if (!mounted || requestId != _cryptoRequestSerial ||
          !_sameStringList(requestedCoins, selectedCryptos)) return;
      setState(() {
        cryptoOverviewByCoin = parsed;
        // 摘要與 K 線使用同一次回應，改選幣種時也同步更新圖表。
        klineDataByCoin = {
          ...klineDataByCoin,
          for (final entry in parsed.entries) entry.key: entry.value.candles,
        };
        final updatedAt = DateTime.now();
        cryptoLastUpdatedAt = updatedAt;
        klineLastUpdatedAt = updatedAt;
      });
    } on TimeoutException {
      if (!mounted || requestId != _cryptoRequestSerial) return;
      setState(() {
        cryptoErrorMessage = '加密貨幣 API 連線逾時，請確認後端服務是否正常運作。';
      });
    } on FormatException catch (error) {
      if (!mounted || requestId != _cryptoRequestSerial) return;
      setState(() {
        cryptoErrorMessage = '加密貨幣 JSON 格式錯誤：${error.message}';
      });
    } catch (error) {
      if (!mounted || requestId != _cryptoRequestSerial) return;
      setState(() {
        cryptoErrorMessage = '加密貨幣資料讀取失敗：$error';
      });
    } finally {
      if (mounted && requestId == _cryptoRequestSerial) {
        setState(() { isCryptoLoading = false; });
      }
    }
  }

  Future<void> _refreshSelectedData() async {
    if (isStableCoinCategory && canLoadStablecoinData) {
      await Future.wait([_loadStablecoinRisk(), _loadKlineData()]);
      return;
    }

    if (isCryptoCategory && hasSelectedCrypto) {
      await Future.wait([_loadCryptoOverview(), _loadKlineData()]);
    }
  }

  void _resetCryptoResult() {
    _cryptoRequestSerial++;
    isCryptoLoading = false;
    cryptoOverviewByCoin = {};
    cryptoErrorMessage = null;
    cryptoLastUpdatedAt = null;
  }

  bool _sameStringList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;

    return a.toSet().containsAll(b) && b.toSet().containsAll(a);
  }

  /// 清除目前 API 結果，但不直接清空左側選項。
  void _resetApiResult() {
    _requestSerial++;
    isLoading = false;
    modelRiskData = {};
    errorMessage = null;
    lastUpdatedAt = null;
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
    var shouldReloadStablecoin = false;
    var shouldLoadKline = false;
    var shouldLoadCrypto = false;

    setState(() {
      // 切換分類時，清空另一分類的選擇與資料。
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
      }

      if (category == '穩定幣') {
        // 點選穩定幣時，右側 K 線同步切換到該幣種。
        if (selectedCoins.contains(coin)) {
          selectedKlineCoin = coin;
        } else if (selectedKlineCoin == coin && selectedCoins.isNotEmpty) {
          selectedKlineCoin = selectedCoins.first;
        }

        if (selectedCoins.isEmpty) {
          selectedModels.clear();
        }

        _resetApiResult();
        shouldReloadStablecoin = canLoadStablecoinData;
      } else {
        // 一般加密貨幣不使用穩定幣模型。
        selectedModels.clear();
        _resetApiResult();
        _resetCryptoResult();

        if (hasSelectedCrypto) {
          // 新勾選的幣種切換到對應 K 線；取消目前幣種時回到其他所選幣種。
          if (selectedCoins.contains(coin)) {
            selectedKlineCoin = coin;
          } else if (!selectedCryptos.contains(selectedKlineCoin)) {
            selectedKlineCoin = selectedCryptos.first;
          }
          shouldLoadCrypto = true;
        }
      }

      shouldLoadKline =
          hasSelectedKlineCoin &&
          (klineDataByCoin[selectedKlineCoin]?.isEmpty ?? true) &&
          !isKlineLoading;
    });

    if (shouldLoadKline) {
      _loadKlineData();
    }

    if (shouldReloadStablecoin) {
      _loadStablecoinRisk();
    }

    if (shouldLoadCrypto) {
      _loadCryptoOverview();
    }
  }

  /// 模型可複選；每次改選後重新抓取所有所選幣種的資料。
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

      _resetApiResult();
    });

    if (canLoadStablecoinData) {
      _loadStablecoinRisk();
    }
  }

  void _clearSelection() {
    setState(() {
      selectedCategory = null;
      selectedCoins.clear();
      selectedModels.clear();
      _resetApiResult();
      _resetCryptoResult();
      _klineRequestSerial++;
      isKlineLoading = false;
      klineErrorMessage = null;
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
            final leftPanel = _buildLeftPanel();
            final rightPanel = _buildRightPanel();

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
              '一般加密貨幣可複選 BTC、ETH、SOL、XRP，查看 K 線與趨勢分數；'
              '穩定幣則可複選 USDC/TUSD 與預測模型。',
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: Colors.white.withValues(alpha: 0.55),
              ),
            ),
            const SizedBox(height: 32),
            _buildHoverCategoryMenu(
              category: '加密貨幣',
              subtitle: 'BTC、ETH、SOL、XRP 趨勢與 K 線',
              coins: cryptoCoins,
              showModels: false,
            ),
            const SizedBox(height: 12),
            _buildHoverCategoryMenu(
              category: '穩定幣',
              subtitle: 'USDC、TUSD 與四種預測模型',
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

  Widget _buildRightPanel() {
    final viewportHeight = MediaQuery.sizeOf(context).height;
    final chartHeight = (viewportHeight * 0.62)
        .clamp(420.0, 560.0)
        .toDouble();

    // 只要目前「沒有實際選到任何幣種或模型」，
    // 不論 selectedCategory 是否仍保留先前的分類，都視為空白狀態。
    //
    // 這樣使用者把左側 USDC / TUSD 等選項逐一取消後，
    // 右側資料顯示區就會恢復成初始的大尺寸，不會縮成 220 px。
    final isEmptySelection =
        selectedCoins.isEmpty &&
        selectedModels.isEmpty;

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
          // 左側選到幣種時顯示右上方 K 線圖。
          if (hasSelectedKlineCoin) ...[
            SizedBox(height: chartHeight, child: _buildKlinePanel()),
            const SizedBox(height: 16),
          ],
          ConstrainedBox(
            constraints: BoxConstraints(minHeight: resultPanelMinHeight),
            child: _buildApiResultPanel(),
          ),
        ],
      ),
    );
  }

  Widget _buildKlinePanel() {
    final candles = activeKlineData;
    final latest = candles.isEmpty ? null : candles.last;
    final latestColor = latest == null || latest.close >= latest.open
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
                      '$selectedKlineCoin K 線圖',
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
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              // 顯示目前分類中的已選幣種；無資料的按鈕會停用。
              for (final coin in selectedKlineCoins)
                _buildKlineCoinButton(coin),
              Text(
                '${candles.length} 根 K 棒 · ${cryptoOverviewByCoin[selectedKlineCoin]?.klineInterval ?? '1h'}',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.white.withValues(alpha: 0.42),
                ),
              ),
            ],
          ),
          if (latest != null) ...[
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _buildKlineValue('開', _formatKlineNumber(latest.open)),
                  _buildKlineValue('高', _formatKlineNumber(latest.high)),
                  _buildKlineValue('低', _formatKlineNumber(latest.low)),
                  _buildKlineValue(
                    '收',
                    _formatKlineNumber(latest.close),
                    valueColor: latestColor,
                  ),
                  _buildKlineValue('量', _formatVolume(latest.volume)),
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
          Expanded(child: _buildKlineChartBody()),
        ],
      ),
    );
  }

  Widget _buildKlineChartBody() {
    final candles = activeKlineData;

    if (isKlineLoading && candles.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (klineErrorMessage != null && candles.isEmpty) {
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

    return InteractiveCandlestickChart(candles: candles);
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
        message: '目前幣種為 ${coins.join('、')}；四個模型皆支援同時複選。',
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
          '已選幣種：${coins.join('、')}　｜　已選模型：${selectedModels.join('、')}',
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
        for (
          int coinIndex = 0;
          coinIndex < coins.length;
          coinIndex++
        ) ...[
          _buildCoinResultSection(coin: coins[coinIndex]),
          if (coinIndex != coins.length - 1) const SizedBox(height: 20),
        ],
      ],
    );
  }

  Widget _buildCryptoResultPanel() {
    final coins = selectedCryptos;
    final selectedData = <CryptoOverviewData>[
      for (final coin in coins)
        if (cryptoOverviewByCoin[coin] != null) cryptoOverviewByCoin[coin]!,
    ];
    final horizons = selectedData
        .map((data) => data.predictionHorizonHours)
        .toSet();
    final predictionRangeNote = horizons.isEmpty
        ? '預測時間範圍：資料載入後顯示'
        : horizons.length == 1
            ? '預測時間範圍：未來 ${horizons.single} 小時'
            : '預測時間範圍：${selectedData.map((data) => '${data.coin} ${data.predictionHorizonHours} 小時').join('、')}';
    if (coins.isEmpty) {
      return _buildEmptyState(
        icon: Icons.currency_bitcoin_rounded,
        title: '請選擇加密貨幣',
        message: '在左側選擇 BTC、ETH、SOL 或 XRP，可同時查看多種幣的趨勢。',
      );
    }
    if (isCryptoLoading && cryptoOverviewByCoin.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (cryptoErrorMessage != null && cryptoOverviewByCoin.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded, color: Colors.redAccent),
            const SizedBox(height: 12),
            SelectableText(
              cryptoErrorMessage!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.redAccent, height: 1.5),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _loadCryptoOverview,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重試'),
            ),
          ],
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text('加密貨幣趨勢預測',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            ),
            if (isCryptoLoading)
              const SizedBox(width: 18, height: 18,
                child: CircularProgressIndicator(strokeWidth: 2)),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          predictionRangeNote,
          style: TextStyle(
            fontSize: 13,
            color: Colors.white.withValues(alpha: 0.65),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          cryptoLastUpdatedAt == null ? '尚未更新'
              : '最後更新：${_formatTime(cryptoLastUpdatedAt!)}',
          style: TextStyle(fontSize: 12,
            color: Colors.white.withValues(alpha: 0.45)),
        ),
        if (cryptoErrorMessage != null) ...[
          const SizedBox(height: 12),
          _buildWarningBanner(cryptoErrorMessage!),
        ],
        const SizedBox(height: 12),
        for (final coin in coins) ...[
          if (cryptoOverviewByCoin[coin] != null)
            _buildCryptoCoinSection(cryptoOverviewByCoin[coin]!)
          else
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text('$coin 尚無後端預測資料'),
            ),
          const SizedBox(height: 12),
        ],
      ],
    );
  }

  Widget _buildCryptoCoinSection(CryptoOverviewData data) {
    final trend = data.trendLabel.toLowerCase();
    // 以後端 trend_label 顯示與上色，不將它改成一定上漲或下跌。
    final trendColor = trend.contains('多') || trend.contains('bull')
        ? const Color(0xFF30D158)
        : trend.contains('空') || trend.contains('bear')
            ? const Color(0xFFFF453A)
            : const Color(0xFF64D2FF);
    final latestClosed = data.latestClosedCandle;
    final scoreDifference = data.scoreDifference;
    final metrics = <Widget>[
      _buildCompactMetricCell(
        title: '目前價格',
        value: latestClosed == null ? '—' : _formatCryptoUsd(latestClosed.close),
        jsonKey: 'data.cryptos[].kline_data[].close',
        subtitle: '最新已收盤 ${data.klineInterval} K 棒的收盤價，作為本次趨勢資料的價格基準',
        color: const Color(0xFF64D2FF),
      ),
      _buildCompactMetricCell(
        title: '上漲分數',
        value: '${data.upScore.toStringAsFixed(2)}／100',
        jsonKey: 'data.cryptos[].up_score',
        subtitle: '未來 ${data.predictionHorizonHours} 小時的模型上漲分數',
        color: const Color(0xFFBF5AF2),
      ),
      _buildCompactMetricCell(
        title: '判斷門檻',
        value: _formatThreshold(data.displayThreshold),
        jsonKey: 'data.cryptos[].display_threshold',
        subtitle: '上漲分數的趨勢顯示門檻',
        color: const Color(0xFFFFD60A),
      ),
      _buildCompactMetricCell(
        title: '距門檻差',
        value: _formatScoreDifference(scoreDifference),
        jsonKey: 'up_score − display_threshold',
        subtitle: '上漲分數減去判斷門檻；正值表示高於門檻，負值表示低於門檻',
        color: _priceDifferenceColor(scoreDifference),
      ),
      _buildCompactMetricCell(
        title: '預測方向',
        value: data.trendLabel,
        jsonKey: 'data.cryptos[].trend_label',
        subtitle: '模型對未來 ${data.predictionHorizonHours} 小時的趨勢判斷',
        color: trendColor,
      ),
      _buildCompactMetricCell(
        title: '模型資料截至',
        value: latestClosed == null
            ? '尚無已收盤資料'
            : '${_formatHourMinute(latestClosed.time)} 已收盤',
        jsonKey: 'timestamp + kline_interval + kline_data[].time',
        subtitle: latestClosed == null
            ? '尚無可確認已收盤的 K 棒'
            : '依後端回應時間與 K 線週期推算；${_formatTime(latestClosed.time)} 起始的 K 棒已收盤。JSON 未提供獨立的模型資料截止時間',
        color: const Color(0xFF64D2FF),
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(data.coin,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        LayoutBuilder(builder: (context, constraints) {
          final columns = constraints.maxWidth >= 1080 ? 6
              : constraints.maxWidth >= 600 ? 3
              : constraints.maxWidth >= 360 ? 2 : 1;
          const spacing = 8.0;
          final width = (constraints.maxWidth - spacing * (columns - 1)) / columns;
          return Wrap(
            spacing: spacing,
            runSpacing: spacing,
            children: [for (final metric in metrics)
              SizedBox(width: width, child: metric)],
          );
        }),
      ],
    );
  }

  /// 顯示單一幣種底下所有已選模型。
  Widget _buildCoinResultSection({required String coin}) {
    final coinData =
        modelRiskData[coin] ?? const <String, StablecoinModelMetrics>{};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
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
            Expanded(
              child: Divider(color: Colors.white.withValues(alpha: 0.08)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        for (
          int modelIndex = 0;
          modelIndex < selectedModels.length;
          modelIndex++
        ) ...[
          if (coinData[selectedModels[modelIndex]] != null)
            _buildModelMetricSection(
              coin: coin,
              modelName: selectedModels[modelIndex],
              data: coinData[selectedModels[modelIndex]]!,
            ),
          if (modelIndex != selectedModels.length - 1)
            const SizedBox(height: 8),
        ],
      ],
    );
  }

  /// 顯示單一模型的五項資料。
  ///
  /// 每個數據都有自己的卡片；桌面寬度足夠時盡量五張排成一列，
  /// 寬度不足時自動切換為三欄、兩欄或單欄。
  Widget _buildModelMetricSection({
    required String coin,
    required String modelName,
    required StablecoinModelMetrics data,
  }) {
    final prefix = _jsonPrefixFor(coin, modelName);

    final metrics = <Widget>[
      _buildCompactMetricCell(
        title: '目前價格',
        value: _formatUsd(data.currentPrice),
        jsonKey: '${prefix}_current_price',
        subtitle: '$coin 目前市場價格',
        color: const Color(0xFF64D2FF),
      ),
      _buildCompactMetricCell(
        title: '6 小時最低價',
        value: _formatUsd(data.future6hLow),
        jsonKey: '${prefix}_future_6h_low',
        subtitle: '$modelName 預測的未來六小時最低價格',
        color: const Color(0xFFBF5AF2),
      ),
      _buildCompactMetricCell(
        title: '價格差',
        value: _formatPriceDifference(data.priceDiff),
        jsonKey: '${prefix}_price_diff',
        subtitle: _priceDiffSubtitle(data.priceDiff),
        color: _priceDifferenceColor(data.priceDiff),
      ),
      _buildCompactMetricCell(
        title: '脫鉤機率',
        value: _formatPercent(data.depegProbability),
        jsonKey: '${prefix}_depeg_probability',
        subtitle: '$modelName 估計的 $coin 脫鉤機率',
        color: _probabilityColor(data.depegProbability),
      ),
      _buildCompactMetricCell(
        title: '風險等級',
        value: data.riskLevel,
        jsonKey: '${prefix}_risk_level',
        subtitle: '後端回傳的風險等級',
        color: _riskLevelColor(data.riskLevel, data.depegProbability),
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
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.analytics_outlined,
                size: 15,
                color: Color(0xFF2997FF),
              ),
              const SizedBox(width: 6),
              Text(
                modelName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 7),
        LayoutBuilder(
          builder: (context, constraints) {
            final int columns;
            if (constraints.maxWidth >= 900) {
              columns = 5;
            } else if (constraints.maxWidth >= 650) {
              columns = 3;
            } else if (constraints.maxWidth >= 390) {
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
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
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
                    turns: isHovered ? 0.5 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: Colors.white.withValues(alpha: 0.65),
                    ),
                  ),
                ],
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              child: isHovered
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
                              canSelectModels ? '模型（可複選）' : '模型（請先至少選一個穩定幣）',
                            ),
                            const SizedBox(height: 8),
                            ...models.map(
                              (model) => _buildMenuOption(
                                text: model,
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
              '模型：${selectedModels.join(', ')}',
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

  /// 一般加密貨幣加入千分位；小額幣保留較多小數以免損失精度。
  String _formatCryptoUsd(double value) {
    final decimals = value.abs() >= 10 ? 2 : value.abs() >= 1 ? 4 : 6;
    final parts = value.toStringAsFixed(decimals).split('.');
    final integerPart = parts.first.replaceAllMapped(
      RegExp(r'(\d)(?=(\d{3})+$)'),
      (match) => '${match.group(1)},',
    );
    return '\$$integerPart.${parts.last}';
  }

  String _formatThreshold(double value) {
    return value == value.truncateToDouble()
        ? value.toInt().toString()
        : value.toStringAsFixed(2);
  }

  String _formatScoreDifference(double value) {
    // 先四捨五入，避免極小差距顯示為 +0.00 或 -0.00。
    final rounded = (value * 100).round() / 100;
    final sign = rounded > 0 ? '+' : rounded < 0 ? '-' : '';
    return '$sign${rounded.abs().toStringAsFixed(2)} 分';
  }

  String _formatHourMinute(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}';
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

  Color _probabilityColor(double probability) {
    if (probability >= 70) return const Color(0xFFFF453A);
    if (probability >= 30) return const Color(0xFFFFD60A);
    return const Color(0xFF30D158);
  }

  /// 優先依後端 risk_level 文字上色；無法辨識時才參考機率。
  Color _riskLevelColor(String riskLevel, double probability) {
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

    return _probabilityColor(probability);
  }
}

/// 可用滑鼠移動查看每一根 K 棒的時間。
///
/// 滑鼠進入價格/成交量繪圖區後，會找出距離游標最近的 K 棒，
/// 並將該筆資料索引交給 [CandlestickChartPainter] 畫出垂直標示線與時間標籤。
class InteractiveCandlestickChart extends StatefulWidget {
  final List<CandlestickData> candles;

  const InteractiveCandlestickChart({
    super.key,
    required this.candles,
  });

  @override
  State<InteractiveCandlestickChart> createState() =>
      _InteractiveCandlestickChartState();
}

class _InteractiveCandlestickChartState
    extends State<InteractiveCandlestickChart> {
  int? _hoveredOriginalIndex;

  @override
  void didUpdateWidget(covariant InteractiveCandlestickChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.candles, widget.candles)) {
      _hoveredOriginalIndex = null;
    }
  }

  void _updateHover(Offset localPosition, Size size) {
    if (widget.candles.isEmpty || size.width < 120 || size.height < 90) {
      _clearHover();
      return;
    }

    const chartLeft = 6.0;
    const rightAxisWidth = 76.0;
    final chartRight = math.max(chartLeft + 20, size.width - rightAxisWidth);
    final chartWidth = chartRight - chartLeft;

    // 滑鼠位於價格刻度區之外時，不顯示 hover。
    if (localPosition.dx < chartLeft || localPosition.dx > chartRight) {
      _clearHover();
      return;
    }

    final widthBasedCount = math.max(8, (chartWidth / 15).floor());
    final maxVisibleCount = math.min(55, widthBasedCount);
    final visibleCount = math.min(widget.candles.length, maxVisibleCount);

    if (visibleCount <= 0) {
      _clearHover();
      return;
    }

    final slotWidth = chartWidth / visibleCount;
    final visibleIndex = ((localPosition.dx - chartLeft) / slotWidth)
        .floor()
        .clamp(0, visibleCount - 1);
    final firstOriginalIndex = widget.candles.length - visibleCount;
    final originalIndex = firstOriginalIndex + visibleIndex;

    if (_hoveredOriginalIndex != originalIndex) {
      setState(() {
        _hoveredOriginalIndex = originalIndex;
      });
    }
  }

  void _clearHover() {
    if (_hoveredOriginalIndex != null) {
      setState(() {
        _hoveredOriginalIndex = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);

        return MouseRegion(
          cursor: SystemMouseCursors.basic,
          onHover: (event) => _updateHover(event.localPosition, size),
          onExit: (_) => _clearHover(),
          child: CustomPaint(
            painter: CandlestickChartPainter(
              candles: widget.candles,
              hoveredOriginalIndex: _hoveredOriginalIndex,
            ),
            child: const SizedBox.expand(),
          ),
        );
      },
    );
  }
}

/// 不依賴第三方圖表套件的 K 線與成交量繪圖器。
class CandlestickChartPainter extends CustomPainter {
  final List<CandlestickData> candles;
  final int? hoveredOriginalIndex;

  const CandlestickChartPainter({
    required this.candles,
    this.hoveredOriginalIndex,
  });

  static const Color _upColor = Color(0xFFFF453A);
  static const Color _downColor = Color(0xFF30D158);
  static const Color _axisTextColor = Color(0xFF85858A);
  static const Color _gridColor = Color(0xFF29292D);

  @override
  void paint(Canvas canvas, Size size) {
    if (candles.isEmpty || size.width < 120 || size.height < 90) return;

    const chartLeft = 6.0;
    const rightAxisWidth = 76.0;
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

    // 減少同時顯示的數量，讓每根 K 棒更寬、更容易辨識。
    final widthBasedCount = math.max(8, (chartWidth / 15).floor());
    final maxVisibleCount = math.min(55, widthBasedCount);
    final visibleCount = math.min(candles.length, maxVisibleCount);
    final firstVisibleOriginalIndex = candles.length - visibleCount;
    final visible = candles.sublist(firstVisibleOriginalIndex);

    final int? hoveredVisibleIndex = hoveredOriginalIndex != null &&
            hoveredOriginalIndex! >= firstVisibleOriginalIndex &&
            hoveredOriginalIndex! < candles.length
        ? hoveredOriginalIndex! - firstVisibleOriginalIndex
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
        fontSize: 12,
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

    // 滑鼠所在 K 棒的垂直十字線。
    if (hoveredVisibleIndex != null) {
      final hoverX = chartLeft + slotWidth * (hoveredVisibleIndex + 0.5);
      canvas.drawLine(
        Offset(hoverX, chartTop),
        Offset(hoverX, chartBottom),
        Paint()
          ..color = Colors.white.withValues(alpha: 0.46)
          ..strokeWidth = 1,
      );
    }

    canvas.restore();

    final timeIndices = <int>{0, visible.length ~/ 2, visible.length - 1};
    for (final index in timeIndices) {
      final centerX = chartLeft + slotWidth * (index + 0.5);
      final label = _formatTimeLabel(visible[index].time);
      final painter = _textPainter(label, color: _axisTextColor, fontSize: 11);
      final maximumX = math.max(chartLeft, chartRight - painter.width);
      final x = (centerX - painter.width / 2)
          .clamp(chartLeft, maximumX)
          .toDouble();
      painter.paint(canvas, Offset(x, chartBottom + 6));
    }

    // Hover 時在時間軸上顯示精確時間，並以深色標籤突顯。
    if (hoveredVisibleIndex != null) {
      final hovered = visible[hoveredVisibleIndex];
      final hoverX = chartLeft + slotWidth * (hoveredVisibleIndex + 0.5);
      final label = _formatFullTimeLabel(hovered.time);
      final painter = _textPainter(
        label,
        color: Colors.white,
        fontSize: 12,
      );

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

      canvas.drawRRect(
        rect,
        Paint()..color = const Color(0xFF2C2C2E),
      );
      painter.paint(
        canvas,
        Offset(boxX + horizontalPadding, boxY + verticalPadding),
      );
    }
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
        oldDelegate.hoveredOriginalIndex != hoveredOriginalIndex;
  }
}
