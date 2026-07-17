import '../models/reading_model.dart';
import '../models/site_model.dart';
import '../models/weather_reading_model.dart';

// Same mismatch margin used elsewhere (review/history screens' officer-vs-AI
// comparison) — reused here so "similar" vs "differing" in the generated
// summary matches what the UI already calls a mismatch.
const double _levelMismatchThreshold = 0.5;

// A reading within 10% of the danger threshold (but not yet at/over it) is
// called out as "approaching" rather than lumped in with "below" — there's
// no existing convention for this in the app, so this is a reasonable,
// self-contained heuristic rather than a value pulled from elsewhere.
const double _approachingMarginFraction = 0.1;

String _twoDigits(int n) => n.toString().padLeft(2, '0');

String _formatDate(DateTime dt) =>
    '${dt.year}-${_twoDigits(dt.month)}-${_twoDigits(dt.day)}';

String _formatTime(DateTime dt) =>
    '${_twoDigits(dt.hour)}:${_twoDigits(dt.minute)}';

/// Builds a natural-language paragraph summarizing a reading for the
/// analyst, combining the reading itself with its site and (optional)
/// weather context. Every piece beyond the opening sentence is optional data
/// (aiDetectedLevel, phLevel, weather, isAlert) and is skipped entirely —
/// not shown as "null" or a blank gap — when not available.
String generateReadingSummary(
  Reading reading,
  Site site,
  WeatherReading? weather,
) {
  final sentences = <String>[
    'On ${_formatDate(reading.timestamp)} at ${_formatTime(reading.timestamp)}, '
        'a reading was submitted at ${site.name} on the ${site.riverName}.',
  ];

  final manualLevel = reading.manualLevel;
  if (manualLevel != null) {
    final dangerLevel = site.dangerLevel;
    final approachingThreshold =
        dangerLevel * (1 - _approachingMarginFraction);
    final String comparison;
    if (manualLevel >= dangerLevel) {
      comparison = 'above';
    } else if (manualLevel >= approachingThreshold) {
      comparison = 'approaching';
    } else {
      comparison = 'below';
    }

    sentences.add(
      'The recorded water level was ${manualLevel.toStringAsFixed(1)}m, '
      '$comparison the site\'s danger threshold of '
      '${dangerLevel.toStringAsFixed(1)}m.',
    );

    final aiLevel = reading.aiDetectedLevel;
    if (aiLevel != null) {
      final similarity =
          (manualLevel - aiLevel).abs() <= _levelMismatchThreshold
          ? 'similar'
          : 'differing';
      sentences.add(
        'The AI-assisted detection estimated a $similarity level of '
        '${aiLevel.toStringAsFixed(1)}m.',
      );
    }
  }

  final phLevel = reading.phLevel;
  if (phLevel != null) {
    sentences.add(
      'The water\'s pH was measured at ${phLevel.toStringAsFixed(1)}.',
    );
  }

  if (weather != null) {
    sentences.add(
      'Current conditions showed '
      '${weather.rainfall1h.toStringAsFixed(1)}mm of rainfall in the past '
      'hour, with ${weather.weatherDescription} and a temperature of '
      '${weather.temperature.toStringAsFixed(1)}°C.',
    );
  }

  if (reading.isAlert) {
    sentences.add('This reading triggered a danger-level alert.');
  }

  return sentences.join(' ');
}
