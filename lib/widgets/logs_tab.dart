import 'package:flutter/material.dart';
import 'package:pkmproject/widgets/resq_ui.dart';

class LogsTab extends StatefulWidget {
  final List<String> logs;
  final VoidCallback onClearLogs;

  const LogsTab({super.key, required this.logs, required this.onClearLogs});

  @override
  State<LogsTab> createState() => _LogsTabState();
}

class _LogsTabState extends State<LogsTab> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Container(
      color: ResqColors.surface,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                const Icon(
                  Icons.info_outline,
                  size: 20,
                  color: ResqColors.muted,
                ),
                const SizedBox(width: 8),
                const Text(
                  'Activity Log',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: ResqColors.field,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.clear, size: 20),
                  color: ResqColors.muted,
                  onPressed: widget.onClearLogs,
                  tooltip: 'Clear logs',
                ),
              ],
            ),
          ),
          Expanded(
            child: widget.logs.isEmpty
                ? const ResqEmptyState(
                    icon: Icons.receipt_long_outlined,
                    title: 'Log Kosong',
                    message: 'Aktivitas relay dan sync akan muncul di sini.',
                  )
                : ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: widget.logs.length,
                    itemBuilder: (context, index) {
                      final log = widget.logs[index];
                      final lower = log.toLowerCase();
                      final isError =
                          lower.contains('error') ||
                          lower.contains('failed') ||
                          lower.contains('gagal');
                      final isSuccess =
                          lower.contains('success') ||
                          lower.contains('started') ||
                          lower.contains('complete') ||
                          lower.contains('selesai');

                      final color = isError
                          ? ResqColors.danger
                          : isSuccess
                          ? ResqColors.safe
                          : ResqColors.muted;

                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: color.withValues(alpha: 0.25),
                            ),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                _iconForLog(isError, isSuccess),
                                size: 16,
                                color: color,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  log,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: color,
                                    fontFamily: 'monospace',
                                    height: 1.4,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  IconData _iconForLog(bool isError, bool isSuccess) {
    if (isError) return Icons.error_outline;
    if (isSuccess) return Icons.check_circle_outline;
    return Icons.info_outline;
  }
}
