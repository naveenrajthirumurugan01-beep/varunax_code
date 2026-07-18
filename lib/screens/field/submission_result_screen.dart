import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../models/reading_model.dart';
import '../../models/site_model.dart';
import '../../models/weather_reading_model.dart';
import '../../utils/report_generator.dart';

/// Shown immediately after a field officer submits a reading — a one-shot
/// "what did I just submit and what does it mean" summary, built entirely
/// from data already produced during submission (the Reading itself, its
/// Site, and optionally the most recent WeatherReading). No new AI models
/// or data sources.
class SubmissionResultScreen extends StatelessWidget {
  const SubmissionResultScreen({
    super.key,
    required this.reading,
    required this.site,
    this.weather,
  });

  final Reading reading;
  final Site site;
  final WeatherReading? weather;

  // Mirrors report_generator.dart's own "approaching" heuristic (within 10%
  // of the danger threshold but not yet at/over it) — kept in sync manually
  // since that file's threshold constant is private to it.
  static const double _approachingMarginFraction = 0.1;

  bool get _isApproaching {
    final level = reading.manualLevel ?? reading.aiDetectedLevel;
    if (level == null || reading.isAlert) return false;
    final approachingThreshold =
        site.dangerLevel * (1 - _approachingMarginFraction);
    return level >= approachingThreshold;
  }

  String get _recommendedAction {
    if (reading.isAlert) {
      return '🚨 This reading exceeds the danger threshold. Your '
          'supervisor has been automatically notified.';
    }
    if (_isApproaching) {
      return '⚠️ Water level is approaching the danger threshold. '
          'Consider a follow-up check soon.';
    }
    return '✓ Reading is within normal range. No immediate action needed.';
  }

  Color get _actionColor {
    if (reading.isAlert) return AppColors.error;
    if (_isApproaching) return Colors.orange.shade800;
    return Colors.green.shade700;
  }

  void _done(BuildContext context) {
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final level = reading.manualLevel ?? reading.aiDetectedLevel;
    final isAlert = reading.isAlert;
    final accentColor = isAlert
        ? AppColors.error
        : (_isApproaching ? Colors.orange.shade800 : null);

    return Scaffold(
      appBar: AppBar(title: const Text('Submission Result')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(
                isAlert ? Icons.warning_rounded : Icons.check_circle,
                color: isAlert ? AppColors.error : Colors.green.shade600,
                size: 72,
              ),
              const SizedBox(height: 12),
              Text(
                isAlert
                    ? 'Alert triggered'
                    : 'Reading recorded successfully',
                textAlign: TextAlign.center,
                style: textTheme.headlineLarge?.copyWith(
                  color: const Color(0xFF000000),
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: _MetricCard(
                      label: 'Recorded Level',
                      value: level != null
                          ? '${level.toStringAsFixed(1)}m'
                          : '—',
                      accentColor: accentColor,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _MetricCard(
                      label: 'Danger Threshold',
                      value: '${site.dangerLevel.toStringAsFixed(1)}m',
                      accentColor: null,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Text(
                'Insight',
                style: textTheme.labelMedium?.copyWith(
                  color: AppColors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                generateReadingSummary(reading, site, weather),
                style: textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFF1A1A1A),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'Recommended Action',
                style: textTheme.labelMedium?.copyWith(
                  color: AppColors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _recommendedAction,
                style: textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: _actionColor,
                ),
              ),
              const SizedBox(height: 32),
              ElevatedButton(
                onPressed: () => _done(context),
                child: const Text('Done'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Same label/value comparison-cell visual language used for level
/// comparisons on the review screen (supervisor/review_screen.dart's
/// _ComparisonCell) and the analyst dashboard's detail dialog — small-caps
/// muted label, large bold value, tinted when accentColor is set.
class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.label,
    required this.value,
    required this.accentColor,
  });

  final String label;
  final String value;
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    final color = accentColor;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      decoration: BoxDecoration(
        color: color != null
            ? color.withValues(alpha: 0.12)
            : AppColors.secondaryContainer,
        borderRadius: BorderRadius.circular(AppSpacing.radiusStandard),
      ),
      child: Column(
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: AppColors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: color ?? AppColors.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}
