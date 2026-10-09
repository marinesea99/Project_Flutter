// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';

import 'package:flutter_application_web_1/main.dart';

List<CandlestickData> _candles(int count) {
  return List.generate(count, (index) {
    final open = 100.0 + index;
    return CandlestickData(
      time: DateTime.utc(2026, 1, 1).add(Duration(hours: index)),
      open: open,
      high: open + 2,
      low: open - 2,
      close: open + 1,
      volume: 1000 + index.toDouble(),
    );
  });
}

Finder _chartPaintFinder() {
  return find.byWidgetPredicate(
    (widget) =>
        widget is CustomPaint && widget.painter is CandlestickChartPainter,
  );
}

CandlestickChartPainter _chartPainter(WidgetTester tester) {
  return tester.widget<CustomPaint>(_chartPaintFinder()).painter!
      as CandlestickChartPainter;
}

void main() {
  testWidgets('Dashboard initial content smoke test', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const CryptoDashboardApp());

    expect(find.text('加密貨幣儀表板'), findsOneWidget);
    expect(find.textContaining('BTC、ETH、SOL、XRP'), findsWidgets);
    expect(find.textContaining('不構成投資建議'), findsOneWidget);
  });

  testWidgets('手機點擊可展開加密貨幣選單', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const CryptoDashboardApp());
    expect(find.text('BTC'), findsNothing);

    await tester.tap(find.text('加密貨幣').first);
    await tester.pumpAndSettle();

    expect(find.text('BTC'), findsOneWidget);
    expect(find.text('ETH'), findsOneWidget);
    expect(find.text('SOL'), findsOneWidget);
    expect(find.text('XRP'), findsOneWidget);
  });

  testWidgets('手機 K 線可點擊並左右滑動', (WidgetTester tester) async {
    CandlestickData? inspected;
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 390,
          height: 340,
          child: InteractiveCandlestickChart(
            candles: _candles(100),
            mobileMode: true,
            onInspectionChanged: (value) => inspected = value,
          ),
        ),
      ),
    );

    final chart = find.byType(InteractiveCandlestickChart);
    final controlsBottom = tester.getBottomLeft(find.byTooltip('放大 K 線')).dy;
    final plotTop = tester.getTopLeft(_chartPaintFinder()).dy;
    expect(controlsBottom, lessThanOrEqualTo(plotTop));

    await tester.tapAt(tester.getCenter(chart));
    await tester.pump();
    expect(_chartPainter(tester).inspectedOriginalIndex, isNotNull);
    expect(_chartPainter(tester).inspectionLocked, isTrue);
    expect(inspected, isNotNull);

    await tester.drag(chart, const Offset(120, 0));
    await tester.pump();
    expect(_chartPainter(tester).windowOffset, greaterThan(0));
    expect(find.text('回最新'), findsOneWidget);
  });

  testWidgets('手機在 K 線上垂直滑動仍可捲動頁面', (WidgetTester tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          height: 500,
          child: ListView(
            controller: controller,
            children: [
              const SizedBox(height: 100),
              SizedBox(
                height: 340,
                child: InteractiveCandlestickChart(
                  candles: _candles(100),
                  mobileMode: true,
                ),
              ),
              const SizedBox(height: 600),
            ],
          ),
        ),
      ),
    );

    await tester.drag(
      find.byType(InteractiveCandlestickChart),
      const Offset(0, -150),
    );
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(0));
  });

  testWidgets('電腦 K 線支援滑鼠查看、平移、縮放及回到最新', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 1000,
          height: 500,
          child: InteractiveCandlestickChart(
            candles: _candles(100),
            mobileMode: false,
          ),
        ),
      ),
    );

    final chart = find.byType(InteractiveCandlestickChart);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: tester.getCenter(chart));
    await mouse.moveTo(tester.getCenter(chart) + const Offset(10, 0));
    await tester.pump();
    expect(_chartPainter(tester).inspectedOriginalIndex, isNotNull);

    final initialVisibleCount = _chartPainter(tester).visibleCount;
    await tester.tap(find.byTooltip('放大 K 線'));
    await tester.pump();
    expect(_chartPainter(tester).visibleCount, lessThan(initialVisibleCount));

    await tester.tap(find.byTooltip('查看較早 K 線'));
    await tester.pump();
    final buttonOffset = _chartPainter(tester).windowOffset;
    expect(buttonOffset, greaterThan(0));

    await tester.tap(find.byTooltip('查看較新 K 線'));
    await tester.pump();
    expect(_chartPainter(tester).windowOffset, lessThan(buttonOffset));

    await tester.drag(chart, const Offset(120, 0));
    await tester.pump();
    expect(_chartPainter(tester).windowOffset, greaterThan(0));

    await tester.tap(find.text('回最新'));
    await tester.pump();
    expect(_chartPainter(tester).windowOffset, 0);
  });
}
