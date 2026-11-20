import 'package:byte/features/albums/places.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('sourcePlace', () {
    test('camera, screenshots and screen recordings', () {
      expect(sourcePlace('/storage/emulated/0/DCIM/Camera/IMG_20261012_101500.jpg'), 'Camera');
      expect(sourcePlace('/storage/emulated/0/DCIM/Screenshots/Screenshot_2026-10-12.jpg'), 'Screenshots');
      expect(sourcePlace('/storage/emulated/0/Pictures/Screenshots/a.png'), 'Screenshots');
      expect(sourcePlace('/storage/emulated/0/DCIM/ScreenRecorder/Screenrecorder-1.mp4'), 'Screen recordings');
      expect(sourcePlace('/storage/emulated/0/Movies/ScreenRecorder/x.mp4'), 'Screen recordings');
    });

    test('other apps', () {
      expect(sourcePlace('/storage/emulated/0/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images/IMG-1.jpg'), 'WhatsApp');
      expect(sourcePlace('/storage/emulated/0/Pictures/Telegram/a.jpg'), 'Telegram');
      expect(sourcePlace('/storage/emulated/0/Pictures/Instagram/a.jpg'), 'Instagram');
      expect(sourcePlace('/storage/emulated/0/Download/a.jpg'), 'Downloads');
    });

    test('any other folder is an album under its own name', () {
      expect(sourcePlace('/storage/emulated/0/Pictures/Edited/a.jpg'), 'Edited');
      expect(sourcePlace('/storage/emulated/0/Pictures/a.jpg'), 'Other pictures');
      expect(sourcePlace('a.jpg'), 'Other pictures');
    });
  });

  group('documentPlace (one clear phrase decides; loose words do not)', () {
    test('real papers', () {
      expect(documentPlace(name: '', text: 'Government of India\nDOB: 01/01/2000\n1234 5678 9012\nAadhaar'), 'ID cards');
      expect(documentPlace(name: '', text: 'INCOME TAX DEPARTMENT  Permanent Account Number Card'), 'ID cards');
      expect(documentPlace(name: '', text: 'CERTIFICATE OF PARTICIPATION\nThis is to certify that Kumar took part'), 'Certificates');
      expect(documentPlace(name: '', text: 'Payment successful\nPaid to Sri Stores\nUPI Ref 1234'), 'Bills & receipts');
      expect(documentPlace(name: '', text: 'ANNA UNIVERSITY HALL TICKET Register Number 71'), 'College');
      expect(documentPlace(name: '', text: 'IRCTC e-ticket PNR No 4512345678 Coach No S5'), 'Tickets & travel');
    });

    test('a chat or a post that only mentions the word is not that paper', () {
      expect(documentPlace(name: '', text: 'Participation certificates can be collected at B305'), isNull);
      expect(documentPlace(name: '', text: 'did you get your passport?'), isNull);
      expect(documentPlace(name: '', text: 'Many students finish college with a degree and no real work experience.'), isNull);
    });

    test('an event poster is a poster, whatever it promises', () {
      expect(documentPlace(name: '', text: 'REGIONAL AI SUMMIT  REGISTRATION  EXCLUSIVE OFFER 500 + GST  participation certificate for all'), 'Posters & events');
      expect(documentPlace(name: '', text: 'DSA CHALLENGE 2026  team of two  register today  certificate of participation'), 'Posters & events');
    });
  });

  group('showsPlace (how sure the phone was)', () {
    test('one thing seen very surely, or two fairly surely', () {
      expect(showsPlace({'food': 91}), 'Food');
      expect(showsPlace({'dish': 70, 'cuisine': 69}), 'Food');
      expect(showsPlace({'vehicle': 88, 'wheel': 60}), 'Vehicles');
    });

    test('a weak guess puts a photo nowhere', () {
      expect(showsPlace({'food': 62}), isNull);
      expect(showsPlace({'vehicle': 60}), isNull);
      expect(showsPlace({'sky': 70}), isNull);
      expect(showsPlace(const {}), isNull);
    });

    test('only one album: the surest', () {
      expect(showsPlace({'food': 93, 'sky': 87}), 'Food');
      expect(showsPlace({'dog': 82, 'sky': 95}), 'Nature & places');
    });

    test('parseScores reads what the reader stored', () {
      expect(parseScores('food=91;dish=74'), {'food': 91, 'dish': 74});
      expect(parseScores('-'), isEmpty);
      expect(parseScores(''), isEmpty);
    });
  });

  group('placesFor', () {
    const cam = '/storage/emulated/0/DCIM/Camera/IMG_1.jpg';

    test('a plain camera photo is only in Camera', () {
      expect(placesFor(kind: 'photo', path: cam, fromGallery: true), ['Camera']);
      expect(placesFor(kind: 'photo', path: cam, fromGallery: true, scores: {'food': 60}), ['Camera']);
    });

    test('what a camera photo surely shows', () {
      expect(placesFor(kind: 'photo', path: cam, fromGallery: true, scores: {'smile': 90, 'sky': 88}), ['Camera', 'People']);
      expect(placesFor(kind: 'photo', path: cam, fromGallery: true, scores: {'food': 95}), ['Camera', 'Food']);
      expect(placesFor(kind: 'photo', path: cam, fromGallery: true, scores: {'dog': 85}), ['Camera', 'Pets & animals']);
    });

    test('a paper is filed by what it is, not by what it shows', () {
      final got = placesFor(kind: 'photo', path: cam, fromGallery: true, scores: {'smile': 90}, text: 'Government of India\nAadhaar 1234 5678 9012');
      expect(got, ['Camera', 'ID cards']);
    });

    test('a long page of writing with no known kind is a paper', () {
      final got = placesFor(kind: 'photo', path: cam, fromGallery: true, text: 'lorem ipsum ' * 40);
      expect(got, ['Camera', 'Papers & notes']);
    });

    test('a screenshot is not an ID card, but a payment is a bill', () {
      const shot = '/storage/emulated/0/DCIM/Screenshots/Screenshot_1.jpg';
      expect(placesFor(kind: 'photo', path: shot, fromGallery: true, text: 'INCOME TAX DEPARTMENT Permanent Account Number'), ['Screenshots']);
      expect(placesFor(kind: 'photo', path: shot, fromGallery: true, text: 'Payment successful\nUPI Ref 123'), ['Screenshots', 'Bills & receipts']);
    });

    test('forwards are not sorted by what they show', () {
      const wa = '/storage/emulated/0/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images/IMG-1.jpg';
      expect(placesFor(kind: 'photo', path: wa, fromGallery: true, scores: {'smile': 95, 'food': 95}), ['WhatsApp']);
      expect(placesFor(kind: 'photo', path: wa, fromGallery: true, text: 'Tax Invoice  Invoice no 12  GSTIN 33ABC'), ['WhatsApp', 'Bills & receipts']);
    });

    test('things added to BYTE by hand', () {
      expect(placesFor(kind: 'photo', path: '/data/files/x.jpg', fromGallery: false, scores: {'cat': 90}), ['Saved in BYTE', 'Pets & animals']);
      expect(placesFor(kind: 'video', path: '/data/files/x.mp4', fromGallery: false), ['Saved in BYTE']);
    });

    test('a gallery photo BYTE took over keeps where it came from', () {
      expect(placesFor(kind: 'photo', path: '/data/files/x.jpg', fromGallery: false, knownSource: 'WhatsApp'), ['WhatsApp']);
    });

    test('the album you chose yourself stands', () {
      expect(placesFor(kind: 'photo', path: cam, fromGallery: true, scores: {'food': 95}, fixed: 'People'), ['Camera', 'People']);
      expect(placesFor(kind: 'photo', path: cam, fromGallery: true, scores: {'food': 95}, fixed: '-'), ['Camera']);
      expect(placesFor(kind: 'doc', path: '/data/files/x.pdf', fromGallery: false, text: 'Hall ticket', fixed: 'Bank'), ['Bank']);
    });

    test('documents', () {
      expect(placesFor(kind: 'doc', path: '/data/files/x.pdf', fromGallery: false, text: 'Hall ticket  Register number 71'), ['College']);
      expect(placesFor(kind: 'doc', path: '/data/files/x.pdf', fromGallery: false, text: 'hello there, how are you'), isEmpty);
      expect(placesFor(kind: 'note', path: '', fromGallery: false), isEmpty);
    });
  });

  test('the strip keeps its order', () {
    expect(placeRank('Camera') < placeRank('People'), isTrue);
    expect(placeRank('People') < placeRank('ID cards'), isTrue);
    expect(placeRank('ID cards') < placeRank('Screenshots'), isTrue);
    expect(placeRank('Screenshots') < placeRank('Some folder'), isTrue);
  });
}
