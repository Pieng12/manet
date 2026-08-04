import 'package:flutter/material.dart';
import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/widgets/resq_ui.dart';

enum MessageFilter { all, active, cancelled, resolved, synced, unsynced }

class MessageFilterBar extends StatelessWidget {
  final MessageFilter selectedFilter;
  final ValueChanged<MessageFilter> onFilterChanged;

  const MessageFilterBar({
    super.key,
    required this.selectedFilter,
    required this.onFilterChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: ResqColors.surface,
        border: Border(bottom: BorderSide(color: ResqColors.line, width: 1)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: MessageFilter.values.map((filter) {
            final isSelected = selectedFilter == filter;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                selected: isSelected,
                label: Text(_getFilterLabel(filter)),
                avatar: Icon(
                  _getFilterIcon(filter),
                  size: 16,
                  color: isSelected ? Colors.white : Colors.grey.shade400,
                ),
                selectedColor: ResqColors.ember,
                checkmarkColor: Colors.white,
                labelStyle: TextStyle(
                  color: isSelected ? Colors.white : Colors.grey.shade300,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                  fontSize: 13,
                ),
                backgroundColor: ResqColors.surfaceRaised,
                side: BorderSide(
                  color: isSelected ? ResqColors.ember : ResqColors.line,
                  width: 1,
                ),
                onSelected: (_) => onFilterChanged(filter),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  String _getFilterLabel(MessageFilter filter) {
    switch (filter) {
      case MessageFilter.all:
        return 'All';
      case MessageFilter.active:
        return 'Active';
      case MessageFilter.cancelled:
        return 'Cancelled';
      case MessageFilter.resolved:
        return 'Resolved';
      case MessageFilter.synced:
        return 'Synced';
      case MessageFilter.unsynced:
        return 'Unsynced';
    }
  }

  IconData _getFilterIcon(MessageFilter filter) {
    switch (filter) {
      case MessageFilter.all:
        return Icons.list;
      case MessageFilter.active:
        return Icons.warning;
      case MessageFilter.cancelled:
        return Icons.cancel;
      case MessageFilter.resolved:
        return Icons.check_circle;
      case MessageFilter.synced:
        return Icons.cloud_done;
      case MessageFilter.unsynced:
        return Icons.cloud_off;
    }
  }

  static List<SOSMessage> applyFilter(
    List<SOSMessage> messages,
    MessageFilter filter,
  ) {
    switch (filter) {
      case MessageFilter.all:
        return messages;
      case MessageFilter.active:
        return messages
            .where((m) => m.status == SOSMessageStatus.active)
            .toList();
      case MessageFilter.cancelled:
        return messages
            .where((m) => m.status == SOSMessageStatus.cancelled)
            .toList();
      case MessageFilter.resolved:
        return messages
            .where((m) => m.status == SOSMessageStatus.resolved)
            .toList();
      case MessageFilter.synced:
        return messages.where((m) => m.isSynced == 1).toList();
      case MessageFilter.unsynced:
        return messages.where((m) => m.isSynced == 0).toList();
    }
  }
}
