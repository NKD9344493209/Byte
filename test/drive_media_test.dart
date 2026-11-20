import 'package:byte/core/drive_media.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Drive pill state', () {
    test('green only when online and connected', () {
      expect(const DriveState(online: true, connected: true).good, isTrue);
      expect(const DriveState(online: false, connected: true).good, isFalse);
      expect(const DriveState(online: true, connected: false).good, isFalse);
      expect(const DriveState(online: false, connected: false).good, isFalse);
    });

    test('copyWith keeps the rest', () {
      const s = DriveState(online: true, connected: true, waiting: 3, waitingBig: true);
      final u = s.copyWith(uploading: true, progress: 0.5);
      expect(u.waiting, 3);
      expect(u.waitingBig, isTrue);
      expect(u.uploading, isTrue);
      expect(u.progress, 0.5);
      expect(u.good, isTrue);
    });
  });

  group('Drive entry', () {
    test('reads a row', () {
      final e = DriveEntry.fromRow({'item_id': 'a', 'remote_id': 'r1', 'state': 'in_drive', 'local': 0, 'keep': 1, 'size': 1200, 'error': ''});
      expect(e.inDrive, isTrue);
      expect(e.local, isFalse);
      expect(e.keep, isTrue);
      expect(e.size, 1200);
    });

    test('not in Drive without a remote id', () {
      final e = DriveEntry.fromRow({'item_id': 'a', 'remote_id': '', 'state': 'in_drive'});
      expect(e.inDrive, isFalse);
      expect(e.local, isTrue); // default: the file is on the phone
    });
  });
}
