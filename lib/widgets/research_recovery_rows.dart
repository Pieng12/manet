import 'package:flutter/material.dart';
import 'package:pkmproject/widgets/resq_ui.dart';

class ResearchRecoveryRows extends StatelessWidget {
  const ResearchRecoveryRows({super.key, required this.summary});

  final Map<dynamic, dynamic> summary;

  String _delay(dynamic value) => value is num && value.isFinite && value >= 0
      ? '${value.toStringAsFixed(2)} ms'
      : 'Tidak terdefinisi';

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 148,
          child: Text(label, style: const TextStyle(color: ResqColors.muted)),
        ),
        Expanded(child: Text(value)),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (summary['recovery_measurement_version'] == null) {
      return const SizedBox.shrink();
    }
    final receivers = summary['recovery_receivers'] as List? ?? [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _row(
          'Target menerima / layak',
          '${summary['recovery_received_targets'] ?? '-'} / '
              '${summary['recovery_eligible_targets'] ?? '-'}',
        ),
        _row(
          'Waktu terverifikasi',
          '${summary['recovery_defined_targets'] ?? '-'} target',
        ),
        _row('Rata-rata pemulihan', _delay(summary['recovery_mean_ms'])),
        for (final item in receivers.whereType<Map>())
          if (item['recovery_eligible'] == true)
            _row('${item['receiver']}', switch (item['recovery_status']) {
              'RECOVERED' => _delay(item['recovery_delay_ms']),
              'NOT_RECOVERED_WITHIN_WINDOW' =>
                'Belum menerima hingga akhir window',
              'NOT_APPLICABLE' => 'Tidak berlaku',
              _ => 'Bukti waktu belum cukup',
            }),
      ],
    );
  }
}
