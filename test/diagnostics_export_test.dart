import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wall_sync/services/diagnostics_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    DiagnosticsService.instance.resetSmoothnessMetrics();
    DiagnosticsService.instance.clearHistoryEntries();
  });

  group('DiagnosticsService Reports & Export Formats', () {
    test('generateTxtReport returns formatted diagnostic report', () async {
      final report = await DiagnosticsService.instance.generateTxtReport();

      expect(report, contains('WALLSYNC RUNTIME DIAGNOSTIC REPORT'));
      expect(report, contains('1. MEMORY & RAM PROFILING'));
      expect(report, contains('2. CPU UTILIZATION'));
      expect(report, contains('3. STORAGE & DISK FOOTPRINT'));
      expect(report, contains('4. UI SMOOTHNESS & 60 FPS JANK METRICS'));
      expect(report, contains('5. RUNTIME STABILITY & HANG DETECTIONS'));
    });

    test('generateDetailedReport contains extended trace and history', () async {
      DiagnosticsService.instance.recordHistoryEntry(
        severity: 'WARN',
        category: 'Frame',
        message: 'Test jank detected',
      );

      final detailed = await DiagnosticsService.instance.generateDetailedReport();

      expect(detailed, contains('DETAILED DIAGNOSTIC TRACE & LOGS'));
      expect(detailed, contains('Execution Mode:'));
      expect(detailed, contains('TELEMETRY LOG ENTRIES'));
      expect(detailed, contains('Test jank detected'));
    });

    test('generateCsvData generates valid CSV structure with header', () async {
      DiagnosticsService.instance.recordHistoryEntry(
        severity: 'INFO',
        category: 'Telemetry',
        message: 'Telemetry sample row',
        cpuPercent: 2.5,
        sysCpuPercent: 12.0,
        rssMb: 140.0,
        privateMb: 180.0,
        smoothness: 99.0,
      );

      final csv = await DiagnosticsService.instance.generateCsvData();
      final lines = csv.trim().split('\n');

      expect(lines.first, contains('Timestamp,ProcessCpuPercent,SystemCpuPercent,WorkingSetMb'));
      expect(lines.length, greaterThanOrEqualTo(2));
      expect(csv, contains('Telemetry sample row'));
    });

    test('generateJsonReport generates valid JSON with schema version 2.0.0', () async {
      final jsonStr = await DiagnosticsService.instance.generateJsonReport();
      final Map<String, dynamic> data = jsonDecode(jsonStr);

      expect(data['schemaVersion'], equals('2.0.0'));
      expect(data['\$schema'], contains('diagnostics-v2.json'));
      expect(data.containsKey('system'), isTrue);
      expect(data.containsKey('memory'), isTrue);
      expect(data.containsKey('cpu'), isTrue);
      expect(data.containsKey('rendering'), isTrue);
      expect(data.containsKey('storage'), isTrue);
      expect(data.containsKey('watchdog'), isTrue);
      expect(data.containsKey('history'), isTrue);
    });

    test('generateSummaryText returns concise clipboard summary', () {
      final summary = DiagnosticsService.instance.generateSummaryText();

      expect(summary, contains('WallSync Pro Diagnostic Summary'));
      expect(summary, contains('• Memory:'));
      expect(summary, contains('• CPU:'));
      expect(summary, contains('• Rendering:'));
      expect(summary, contains('• Overlays:'));
    });

    test('generateSupportPackageZip creates valid ZIP with all required diagnostics files', () async {
      final zipFile = await DiagnosticsService.instance.generateSupportPackageZip(
        'test_support_package.zip',
      );

      expect(await zipFile.exists(), isTrue);

      final bytes = await zipFile.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      final fileNames = archive.files.map((f) => f.name).toSet();
      expect(fileNames.contains('report.txt'), isTrue);
      expect(fileNames.contains('detailed_trace.txt'), isTrue);
      expect(fileNames.contains('metrics.csv'), isTrue);
      expect(fileNames.contains('diagnostics.json'), isTrue);
      expect(fileNames.contains('summary.txt'), isTrue);

      // Clean up test zip
      try {
        await zipFile.delete();
      } catch (_) {}
    });

    test('getHistoryEntries filters correctly by severity and category', () {
      final diag = DiagnosticsService.instance;
      diag.recordHistoryEntry(severity: 'INFO', category: 'Telemetry', message: 'T1');
      diag.recordHistoryEntry(severity: 'WARN', category: 'Frame', message: 'F1');
      diag.recordHistoryEntry(severity: 'ERROR', category: 'Watchdog', message: 'W1');

      final all = diag.getHistoryEntries();
      expect(all.length, equals(3));

      final warnOnly = diag.getHistoryEntries(severity: 'WARN');
      expect(warnOnly.length, equals(1));
      expect(warnOnly.first.message, equals('F1'));

      final watchdogOnly = diag.getHistoryEntries(category: 'Watchdog');
      expect(watchdogOnly.length, equals(1));
      expect(watchdogOnly.first.message, equals('W1'));

      diag.clearHistoryEntries();
      expect(diag.getHistoryEntries(), isEmpty);
    });

    test('clearDiagnostics clears history, hang events and resets smoothness', () async {
      final diag = DiagnosticsService.instance;
      diag.recordHistoryEntry(severity: 'WARN', category: 'Frame', message: 'Jank');

      await diag.clearDiagnostics();

      expect(diag.getHistoryEntries(), isEmpty);
      expect(diag.getSmoothnessSnapshot().totalFrames, equals(0));
    });
  });
}

