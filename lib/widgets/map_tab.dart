import 'package:flutter/material.dart';
import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/widgets/sos_map_view.dart';
import 'package:pkmproject/services/database_helper.dart';

class MapTab extends StatefulWidget {
  final Stream<List<SOSMessage>> messageStream;

  const MapTab({super.key, required this.messageStream});

  @override
  State<MapTab> createState() => _MapTabState();
}

class _MapTabState extends State<MapTab> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context); // Important: Must call super.build
    return StreamBuilder<List<SOSMessage>>(
      stream: widget.messageStream,
      initialData:
          DatabaseHelper().currentMessages, // Use cached data on rebuild
      builder: (context, snapshot) {
        // Show map immediately even if no data yet (local data loads fast)
        final messages = snapshot.data ?? [];
        return SosMapView(messages: messages);
      },
    );
  }
}
