import 'package:flutter/material.dart';
import 'package:pkmproject/widgets/resq_ui.dart';

class StatusIndicator extends StatelessWidget {
  final String label;
  final bool isActive;
  final IconData activeIcon;
  final IconData inactiveIcon;
  final Color activeColor;
  final Color inactiveColor;

  const StatusIndicator({
    super.key,
    required this.label,
    required this.isActive,
    required this.activeIcon,
    required this.inactiveIcon,
    this.activeColor = Colors.green,
    this.inactiveColor = Colors.grey,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isActive
            ? activeColor.withValues(alpha: 0.12)
            : inactiveColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isActive ? activeColor : ResqColors.line,
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isActive ? activeIcon : inactiveIcon,
            size: 16,
            color: isActive ? activeColor : inactiveColor,
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: isActive ? activeColor : ResqColors.muted,
            ),
          ),
        ],
      ),
    );
  }
}
