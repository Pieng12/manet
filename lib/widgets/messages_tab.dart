import 'package:flutter/material.dart';
import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/widgets/message_filter_bar.dart';
import 'package:pkmproject/widgets/resq_ui.dart';
import 'package:pkmproject/widgets/sos_message_card.dart';

class MessagesTab extends StatefulWidget {
  final Stream<List<SOSMessage>> messageStream;
  final Function(SOSMessage) onShowActiveSOSDialog;
  final Function(SOSMessage) onDeleteMessage;
  final String deviceId;

  const MessagesTab({
    super.key,
    required this.messageStream,
    required this.onShowActiveSOSDialog,
    required this.onDeleteMessage,
    required this.deviceId,
  });

  @override
  State<MessagesTab> createState() => _MessagesTabState();
}

class _MessagesTabState extends State<MessagesTab>
    with AutomaticKeepAliveClientMixin {
  MessageFilter _selectedFilter = MessageFilter.all;

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context); // Important: Must call super.build
    return StreamBuilder<List<SOSMessage>>(
      stream: widget.messageStream,
      builder: (context, snapshot) {
        // Show empty state immediately if no data yet (local data loads fast)
        if (!snapshot.hasData) {
          return const ResqEmptyState(
            icon: Icons.message_outlined,
            title: 'Belum Ada Pesan',
            message: 'SOS yang diterima atau dibuat akan muncul di sini.',
          );
        }
        if (snapshot.hasError) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, size: 60, color: Colors.red),
                const SizedBox(height: 16),
                Text(
                  'Error: ${snapshot.error}',
                  style: const TextStyle(color: Colors.red),
                ),
              ],
            ),
          );
        }

        final allMessages = snapshot.data!;
        final filteredMessages = MessageFilterBar.applyFilter(
          allMessages,
          _selectedFilter,
        );

        return Column(
          children: [
            MessageFilterBar(
              selectedFilter: _selectedFilter,
              onFilterChanged: (filter) {
                setState(() {
                  _selectedFilter = filter;
                });
              },
            ),
            Expanded(
              child: filteredMessages.isEmpty
                  ? Center(
                      child: const ResqEmptyState(
                        icon: Icons.filter_alt_off,
                        title: 'Tidak Ada Pesan',
                        message: 'Coba pilih filter lain untuk melihat data.',
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 100),
                      itemCount: filteredMessages.length,
                      itemBuilder: (context, index) {
                        final message = filteredMessages[index];
                        final isOwn = message.senderId == widget.deviceId;
                        return SosMessageCard(
                          message: message,
                          isOwnMessage: isOwn,
                          onTap: () {
                            if (isOwn &&
                                message.status == SOSMessageStatus.active) {
                              widget.onShowActiveSOSDialog(message);
                            }
                          },
                          onDelete: () => widget.onDeleteMessage(message),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}
