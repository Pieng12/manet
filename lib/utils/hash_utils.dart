import 'dart:convert';

// Simple CRC32 implementation for stable 4-byte identifiers
// Polynomial: 0xEDB88320

int crc32(String input) {
  final bytes = utf8.encode(input);
  int crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc ^= b;
    for (int i = 0; i < 8; i++) {
      if ((crc & 1) != 0) {
        crc = (crc >> 1) ^ 0xEDB88320;
      } else {
        crc = crc >> 1;
      }
    }
  }
  return crc ^ 0xFFFFFFFF;
}
