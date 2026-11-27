import 'package:chan_kline/data/telegram_data_source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parse daily csv filters by date range', () {
    const csv = '''date,open,high,low,close,volume,amount
2026-10-28,11.43,11.50,11.22,11.31,1687009,1911547776
2026-10-29,11.30,11.55,11.29,11.54,1993504,2283899648
'''; 
    final bars = TelegramDataSource.parseDailyCsvText(
      csv,
      begin: DateTime.utc(2026, 10, 28),
      end: DateTime.utc(2026, 10, 29, 23, 59),
    );
    expect(bars.length, 2);
    expect(bars.first.close, closeTo(11.31, 0.001));
    expect(bars.last.close, closeTo(11.54, 0.001));
  });
}
