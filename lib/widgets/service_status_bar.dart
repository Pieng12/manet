import 'package:flutter/material.dart';
import 'package:pkmproject/widgets/resq_ui.dart';
import 'package:pkmproject/widgets/status_indicator.dart';

class ServiceStatusBar extends StatelessWidget {
  final bool isBleScanning;
  final bool isBleAdvertising;
  final bool isSyncingEnabled;
  final VoidCallback? onToggle;

  const ServiceStatusBar({
    super.key,
    required this.isBleScanning,
    required this.isBleAdvertising,
    required this.isSyncingEnabled,
    this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final isAnyRunning = isBleScanning || isBleAdvertising;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: ResqColors.surface,
        border: Border(bottom: BorderSide(color: ResqColors.line, width: 1)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                StatusIndicator(
                  label: 'BLE Scan',
                  isActive: isBleScanning,
                  activeIcon: Icons.radar,
                  inactiveIcon: Icons.bluetooth_disabled,
                  activeColor: ResqColors.signal,
                ),
                StatusIndicator(
                  label: 'BLE Advertise',
                  isActive: isBleAdvertising,
                  activeIcon: Icons.bluetooth_searching,
                  inactiveIcon: Icons.bluetooth_disabled,
                  activeColor: ResqColors.safe,
                ),
                StatusIndicator(
                  label: 'Gateway',
                  isActive: isSyncingEnabled,
                  activeIcon: Icons.cloud_done,
                  inactiveIcon: Icons.cloud_off,
                  activeColor: ResqColors.ember,
                ),
              ],
            ),
          ),
          if (onToggle != null)
            IconButton(
              icon: Icon(
                isAnyRunning ? Icons.power_settings_new : Icons.power_off,
                color: isAnyRunning ? ResqColors.safe : ResqColors.muted,
              ),
              tooltip: isAnyRunning ? 'Stop BLE Relay' : 'Start BLE Relay',
              onPressed: onToggle,
            ),
        ],
      ),
    );
  }
}
