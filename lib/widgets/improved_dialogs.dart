import 'package:flutter/material.dart';
import 'package:pkmproject/models/sos_message.dart';
import 'package:pkmproject/widgets/resq_ui.dart';

/// Improved dialog widgets with better UX
class ImprovedDialogs {
  /// Beautiful confirmation dialog
  static Future<bool?> showConfirmDialog(
    BuildContext context, {
    required String title,
    required String message,
    String confirmText = 'Confirm',
    String cancelText = 'Cancel',
    Color? confirmColor,
    IconData? icon,
  }) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: ResqColors.surfaceRaised,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        title: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, color: confirmColor ?? ResqColors.ember, size: 28),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
        content: Text(
          message,
          style: TextStyle(fontSize: 15, color: ResqColors.field, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              cancelText,
              style: TextStyle(
                color: ResqColors.muted,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: confirmColor ?? ResqColors.ember,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: Text(
              confirmText,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  /// Improved Active SOS dialog
  static Future<void> showActiveSOSDialog(
    BuildContext context, {
    required VoidCallback onCancel,
    required VoidCallback onReplace,
  }) async {
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ResqColors.surfaceRaised,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: ResqColors.danger.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.warning_amber_rounded,
                color: ResqColors.danger,
                size: 28,
              ),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'SOS Aktif Terdeteksi',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Kamu sudah punya SOS aktif. Pilih tindakan berikutnya.',
              style: TextStyle(
                fontSize: 15,
                color: ResqColors.field,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: ResqColors.ember.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: ResqColors.ember.withValues(alpha: 0.35),
                  width: 1,
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: ResqColors.ember, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Ganti SOS akan memperbarui lokasi dan waktu kejadian.',
                      style: TextStyle(fontSize: 12, color: ResqColors.field),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(
              'Tutup',
              style: TextStyle(color: ResqColors.muted, fontSize: 15),
            ),
          ),
          OutlinedButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              onCancel();
            },
            style: OutlinedButton.styleFrom(
              foregroundColor: ResqColors.ember,
              side: BorderSide(color: ResqColors.ember.withValues(alpha: 0.6)),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: const Text(
              'Batalkan SOS',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              onReplace();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: ResqColors.danger,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: const Text(
              'Perbarui SOS',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  /// Delete confirmation dialog
  static Future<bool?> showDeleteConfirmDialog(
    BuildContext context,
    SOSMessage message,
  ) {
    return showConfirmDialog(
      context,
      title: 'Hapus Pesan?',
      message:
          'Pesan akan dihapus dari perangkat ini saja. Salinan di perangkat lain tetap ada sampai sinkronisasi berikutnya.',
      confirmText: 'Hapus',
      cancelText: 'Batal',
      confirmColor: ResqColors.danger,
      icon: Icons.delete_outline,
    );
  }
}
