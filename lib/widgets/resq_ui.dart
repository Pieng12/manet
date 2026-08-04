import 'package:flutter/material.dart';

class ResqColors {
  static const Color ink = Color(0xFF0B1114);
  static const Color surface = Color(0xFF121A1F);
  static const Color surfaceRaised = Color(0xFF182229);
  static const Color line = Color(0xFF2B3A42);
  static const Color ember = Color(0xFFFF7A1A);
  static const Color danger = Color(0xFFE53935);
  static const Color safe = Color(0xFF2EBD85);
  static const Color signal = Color(0xFF2EA6FF);
  static const Color field = Color(0xFFD6E2E8);
  static const Color muted = Color(0xFF8EA2AD);
}

class ResqFeedback {
  static void success(BuildContext context, String message) {
    _show(context, message, Icons.check_circle_outline, ResqColors.safe);
  }

  static void warning(BuildContext context, String message) {
    _show(context, message, Icons.warning_amber_rounded, ResqColors.ember);
  }

  static void error(BuildContext context, String message) {
    _show(context, message, Icons.error_outline, ResqColors.danger);
  }

  static void info(BuildContext context, String message) {
    _show(context, message, Icons.info_outline, ResqColors.signal);
  }

  static void _show(
    BuildContext context,
    String message,
    IconData icon,
    Color color,
  ) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: ResqColors.surfaceRaised,
        elevation: 8,
        margin: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: color),
        ),
        content: Row(
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ResqSectionHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Color color;

  const ResqSectionHeader({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.color = ResqColors.ember,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color.withValues(alpha: 0.55)),
          ),
          child: Icon(icon, color: color, size: 24),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle!,
                  style: const TextStyle(
                    color: ResqColors.muted,
                    fontSize: 13,
                    height: 1.35,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class ResqEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final Color color;

  const ResqEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.color = ResqColors.muted,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: color.withValues(alpha: 0.45)),
              ),
              child: Icon(icon, color: color, size: 34),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: ResqColors.muted,
                fontSize: 13,
                height: 1.35,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
