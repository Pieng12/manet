import 'package:flutter/material.dart';
import 'package:pkmproject/models/sos_message.dart';
import 'package:intl/intl.dart';
import 'package:pkmproject/widgets/resq_ui.dart';

class SosMessageCard extends StatelessWidget {
  final SOSMessage message;
  final bool isOwnMessage;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;

  const SosMessageCard({
    super.key,
    required this.message,
    this.isOwnMessage = false,
    this.onTap,
    this.onDelete,
  });

  Color _getStatusColor() {
    switch (message.status) {
      case SOSMessageStatus.active:
        return ResqColors.danger;
      case SOSMessageStatus.cancelled:
        return ResqColors.ember;
      case SOSMessageStatus.resolved:
        return ResqColors.safe;
    }
  }

  IconData _getStatusIcon() {
    switch (message.status) {
      case SOSMessageStatus.active:
        return Icons.warning;
      case SOSMessageStatus.cancelled:
        return Icons.cancel;
      case SOSMessageStatus.resolved:
        return Icons.check_circle;
    }
  }

  @override
  Widget build(BuildContext context) {
    final statusColor = _getStatusColor();
    final statusIcon = _getStatusIcon();
    final dateFormat = DateFormat('MMM dd, yyyy HH:mm:ss');

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: ResqColors.surfaceRaised,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: isOwnMessage
              ? ResqColors.signal.withValues(alpha: 0.7)
              : ResqColors.line,
          width: isOwnMessage ? 2 : 1,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            gradient: isOwnMessage
                ? LinearGradient(
                    colors: [
                      ResqColors.signal.withValues(alpha: 0.16),
                      ResqColors.surfaceRaised,
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  )
                : null,
          ),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header Row
              Row(
                children: [
                  // Status Badge
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: statusColor, width: 1),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(statusIcon, size: 16, color: statusColor),
                        const SizedBox(width: 6),
                        Text(
                          message.status.name.toUpperCase(),
                          style: TextStyle(
                            color: statusColor,
                            fontWeight: FontWeight.bold,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  // Delete button (only for non-own messages or cancelled/resolved own messages)
                  if (onDelete != null &&
                      (!isOwnMessage ||
                          message.status != SOSMessageStatus.active))
                    IconButton(
                      icon: Icon(
                        Icons.delete_outline,
                        size: 18,
                        color: Colors.grey.shade400,
                      ),
                      onPressed: onDelete,
                      tooltip: 'Delete message',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  const SizedBox(width: 8),
                  // Sync Status
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: message.isSynced == 1
                          ? ResqColors.safe.withValues(alpha: 0.16)
                          : ResqColors.ember.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          message.isSynced == 1
                              ? Icons.cloud_done
                              : Icons.cloud_off,
                          size: 14,
                          color: message.isSynced == 1
                              ? ResqColors.safe
                              : ResqColors.ember,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          message.isSynced == 1 ? 'Synced' : 'Pending',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: message.isSynced == 1
                                ? ResqColors.safe
                                : ResqColors.ember,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Sender Info
              Row(
                children: [
                  CircleAvatar(
                    radius: 20,
                    backgroundColor: isOwnMessage
                        ? ResqColors.signal
                        : ResqColors.line,
                    child: Icon(
                      isOwnMessage ? Icons.person : Icons.person_outline,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          message.senderName ?? message.senderId,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (isOwnMessage)
                          Text(
                            'Your Message',
                            style: TextStyle(
                              fontSize: 12,
                              color: ResqColors.signal,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Content
              if (message.content.isNotEmpty)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: ResqColors.ink.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    message.content,
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
              const SizedBox(height: 12),
              // Location Info
              Row(
                children: [
                  Icon(Icons.location_on, size: 18, color: ResqColors.danger),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${message.latitude.toStringAsFixed(6)}, ${message.longitude.toStringAsFixed(6)}',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey.shade300,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Timestamp
              Row(
                children: [
                  Icon(
                    Icons.access_time,
                    size: 14,
                    color: Colors.grey.shade400,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    dateFormat.format(
                      DateTime.fromMillisecondsSinceEpoch(message.updatedAt),
                    ),
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
