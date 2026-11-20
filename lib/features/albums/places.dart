/// Where BYTE files a photo, a video or a document by itself — pure
/// functions (no Flutter, no database), so they are unit-tested.
///
/// Every picture has one SOURCE (where it came from: Camera, Screenshots,
/// WhatsApp…) and at most ONE more album: what it IS (an ID card, a bill, a
/// poster) or what it SHOWS (people, food, nature). The rules are strict on
/// purpose: a picture BYTE is not sure about stays only in its source album
/// — a small album that is right beats a big one that is half wrong.
///
/// All of it is worked out on the phone from the file's place, the words
/// read inside it and what the phone's own picture recognition saw (with how
/// sure it was). Nothing is moved or renamed.
library;

/// The albums' names.
class Places {
  Places._();

  static const camera = 'Camera';
  static const saved = 'Saved in BYTE';
  static const screenshots = 'Screenshots';
  static const screenRecordings = 'Screen recordings';
  static const whatsapp = 'WhatsApp';
  static const telegram = 'Telegram';
  static const instagram = 'Instagram';
  static const snapchat = 'Snapchat';
  static const facebook = 'Facebook';
  static const downloads = 'Downloads';
  static const otherPictures = 'Other pictures';

  static const people = 'People';
  static const nature = 'Nature & places';
  static const food = 'Food';
  static const pets = 'Pets & animals';
  static const vehicles = 'Vehicles';

  static const ids = 'ID cards';
  static const college = 'College';
  static const certificates = 'Certificates';
  static const bills = 'Bills & receipts';
  static const bank = 'Bank';
  static const tickets = 'Tickets & travel';
  static const posters = 'Posters & events';
  static const papers = 'Papers & notes';
}

/// The album a gallery picture belongs to by where it lies on the phone.
/// [path] is the file's full path ("/storage/emulated/0/DCIM/Camera/x.jpg").
String sourcePlace(String path) {
  final s = path.toLowerCase().replaceAll('\\', '/');
  if (s.contains('screenshot') || s.contains('screen_shot')) return Places.screenshots;
  if (s.contains('screenrecord') || s.contains('screen_record') || s.contains('screen record') || s.contains('/dcim/screen')) return Places.screenRecordings;
  if (s.contains('whatsapp')) return Places.whatsapp;
  if (s.contains('telegram')) return Places.telegram;
  if (s.contains('instagram')) return Places.instagram;
  if (s.contains('snapchat')) return Places.snapchat;
  if (s.contains('facebook') || s.contains('messenger')) return Places.facebook;
  if (s.contains('/download/') || s.contains('/downloads/')) return Places.downloads;
  if (s.contains('/dcim/')) return Places.camera;
  // Any other folder is its own album, under the folder's name.
  final folders = path.replaceAll('\\', '/').split('/').where((x) => x.isNotEmpty).toList();
  if (folders.length >= 2) {
    final name = folders[folders.length - 2].trim();
    // "0" / "emulated" / "Pictures" say nothing.
    if (name.isNotEmpty && !RegExp(r'^\d+$').hasMatch(name) && !const {'emulated', 'pictures', 'movies', 'sdcard', 'storage'}.contains(name.toLowerCase())) {
      return name.length > 28 ? name.substring(0, 28) : name;
    }
  }
  return Places.otherPictures;
}

// ───────────── what kind of paper it is ─────────────

/// One kind of document. A [sure] phrase alone decides; of the [hints] at
/// least [need] different ones must be there.
class _Paper {
  const _Paper(this.name, {this.sure = const [], this.hints = const [], this.need = 2, this.overPoster});
  final String name;
  final List<String> sure;
  final List<String> hints;
  final int need;

  /// The [sure] phrases that still count on something that reads like a
  /// poster (a poster may say "certificate of participation for all").
  /// null = all of them.
  final List<String>? overPoster;
}

const _papers = <_Paper>[
  _Paper(
    Places.ids,
    sure: ['unique identification authority', 'permanent account number', 'income tax department', 'election commission of india', 'driving licence no', 'driving license no', 'passport no'],
    hints: ['aadhaar', 'aadhar', 'uidai', 'government of india', 'govt. of india', 'date of birth', 'dob:', 'voter', 'epic no', 'licence no', 'license no', 'dl no', 'republic of india', 'passport', 'driving licence', 'driving license'],
    need: 3,
    overPoster: ['unique identification authority', 'permanent account number', 'election commission of india'],
  ),
  _Paper(
    Places.college,
    sure: ['hall ticket', 'question paper', 'statement of marks', 'mark sheet', 'marksheet', 'grade sheet', 'grade card', 'internal assessment', 'consolidated mark'],
    hints: ['semester', 'register number', 'reg. no', 'reg no', 'roll no', 'examination', 'syllabus', 'time table', 'timetable', 'course code', 'credits', 'cgpa', 'sgpa', 'answer all questions', 'max. marks', 'maximum marks'],
    need: 3,
    overPoster: ['hall ticket', 'question paper', 'statement of marks', 'mark sheet', 'marksheet', 'grade sheet'],
  ),
  _Paper(
    Places.certificates,
    sure: ['this is to certify', 'is hereby awarded', 'has successfully completed', 'certificate of completion', 'certificate of participation', 'certificate of appreciation', 'certificate of merit', 'certificate of achievement', 'certificate of excellence'],
    overPoster: ['this is to certify', 'is hereby awarded'],
  ),
  _Paper(
    Places.bills,
    sure: ['payment successful', 'transaction successful', 'upi ref', 'upi transaction id', 'tax invoice', 'invoice no', 'gstin'],
    hints: ['paid to', 'transaction id', 'bill no', 'amount paid', 'invoice', 'receipt', 'subtotal', 'sub total', 'grand total', 'total amount', 'qty', 'mrp', 'cashier', 'order id', 'net amount'],
  ),
  _Paper(
    Places.bank,
    sure: ['statement of account', 'account statement', 'passbook'],
    hints: ['ifsc', 'account number', 'account no', 'a/c no', 'micr', 'cheque', 'closing balance', 'available balance'],
  ),
  _Paper(
    Places.tickets,
    sure: ['boarding pass', 'e-ticket', 'eticket', 'pnr no', 'pnr:'],
    hints: ['irctc', 'redbus', 'seat no', 'coach no', 'boarding point', 'date of journey', 'bookmyshow', 'booking id', 'pnr'],
  ),
];

/// Words of an event poster or an invitation.
const _posterWords = <String>[
  'registration', 'register', 'enroll', 'workshop', 'hackathon', 'webinar', 'join us', 'last date', 'prize', 'venue', 'limited seats',
  'entry fee', 'team of', 'challenge', 'expo', 'summit', 'symposium', 'online meet', 'participation certificate', 'exclusive offer',
  'invites you', 'cordially', 'chief guest', 'speaker', 'free entry',
];

final RegExp _aadhaarNumber = RegExp(r'\b\d{4}\s\d{4}\s\d{4}\b');

bool _letter(int c) => (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x7a);

/// True when [w] stands in [hay] as whole words ("venue" is not in "revenue",
/// "paid to" is not in "paid today"); a plural s is let through.
bool _has(String hay, String w) {
  var from = 0;
  while (true) {
    final at = hay.indexOf(w, from);
    if (at < 0) return false;
    var end = at + w.length;
    final startOk = !_letter(w.codeUnitAt(0)) || at == 0 || !_letter(hay.codeUnitAt(at - 1));
    if (end < hay.length && hay.codeUnitAt(end) == 0x73) end++;
    final endOk = !_letter(w.codeUnitAt(w.length - 1)) || end == hay.length || !_letter(hay.codeUnitAt(end));
    if (startOk && endOk) return true;
    from = at + 1;
  }
}

int _different(String hay, List<String> words) {
  var n = 0;
  for (final w in words) {
    if (_has(hay, w)) n++;
  }
  return n;
}

/// The kind of document a file is, from the words read inside it and its
/// name — or null when BYTE is not sure.
///
/// ID cards, College, Certificates, Bills & receipts, Bank, Tickets &
/// travel, Posters & events. One clear phrase ("this is to certify",
/// "payment successful") decides; loose words ("certificate", "university")
/// alone never do.
String? documentPlace({required String name, required String text}) {
  // (All white space becomes one space: "CERTIFICATE\nOF PARTICIPATION" is one phrase.)
  final hay = '${name.toLowerCase()}\n${text.toLowerCase()}'.replaceAll(RegExp(r'\s+'), ' ');
  if (hay.trim().length < 12) return null;
  final posterWords = _different(hay, _posterWords);
  final poster = posterWords >= 3;
  // Two such words already make "certificate of participation" a promise, not a certificate.
  final promises = posterWords >= 2;
  // An Aadhaar number next to the word is as good as a clear phrase.
  if (_aadhaarNumber.hasMatch(hay) && (hay.contains('aadhaar') || hay.contains('aadhar') || hay.contains('uidai') || hay.contains('government of india'))) return Places.ids;
  for (final p in _papers) {
    if ((promises ? (p.overPoster ?? p.sure) : p.sure).any((w) => _has(hay, w))) return p.name;
  }
  if (poster) return Places.posters;
  for (final p in _papers) {
    if (p.hints.isNotEmpty && _different(hay, p.hints) >= p.need) return p.name;
  }
  return null;
}

// ───────────── what a picture shows ─────────────

/// What the phone's picture recognition is good at, per album. A picture
/// goes in when ONE of these is seen very surely ([one]) or TWO fairly
/// surely ([two]) — how sure is 0 to 100.
class _Shows {
  const _Shows(this.name, this.labels, {required this.one, required this.two});
  final String name;
  final Set<String> labels;
  final int one;
  final int two;
}

const _shows = <_Shows>[
  _Shows(Places.food, {'food', 'dish', 'cuisine', 'meal', 'dessert', 'fast food', 'cake', 'pizza', 'bread', 'cookie', 'fruit', 'vegetable', 'lunch', 'supper', 'hot dog', 'cheeseburger', 'couscous', 'gelato', 'bento', 'cappuccino', 'coffee', 'juice'}, one: 82, two: 68),
  _Shows(Places.people, {'selfie', 'smile', 'crowd', 'team', 'baby', 'bride', 'laugh', 'person', 'beard', 'moustache', 'eyelash', 'dude', 'graduation'}, one: 80, two: 66),
  _Shows(Places.pets, {'dog', 'cat', 'pet', 'bird', 'horse', 'cattle', 'shetland sheepdog', 'gerbil', 'butterfly', 'insect', 'duck', 'bear', 'wildlife'}, one: 80, two: 68),
  _Shows(Places.vehicles, {'car', 'vehicle', 'motorcycle', 'bicycle', 'bus', 'truck', 'van', 'train', 'aircraft', 'airplane', 'boat', 'watercraft', 'tractor', 'wheel', 'tire', 'bumper', 'windshield'}, one: 84, two: 70),
  _Shows(Places.nature, {'sky', 'mountain', 'beach', 'sea', 'ocean', 'lake', 'river', 'forest', 'jungle', 'waterfall', 'sunset', 'flower', 'garden', 'cliff', 'desert', 'tree', 'plant', 'petal', 'reef', 'iceberg'}, one: 92, two: 72),
];

const _paperLabels = {'paper', 'poster', 'whiteboard', 'handwriting', 'menu', 'document', 'text', 'receipt'};

/// The one album for what a photo shows, or null when nothing is seen surely
/// enough. [scores]: what was seen → how sure (0–100).
String? showsPlace(Map<String, int> scores) {
  String? best;
  var bestScore = 0;
  for (final s in _shows) {
    var top = 0;
    var second = 0;
    for (final l in s.labels) {
      final v = scores[l] ?? 0;
      if (v > top) {
        second = top;
        top = v;
      } else if (v > second) {
        second = v;
      }
    }
    final sure = top >= s.one || (top >= s.two && second >= s.two);
    if (sure && top > bestScore) {
      best = s.name;
      bestScore = top;
    }
  }
  return best;
}

/// "food=91;dish=74" (how the reader stores what it saw) → {food: 91, dish: 74}.
Map<String, int> parseScores(String seen) {
  final out = <String, int>{};
  for (final part in seen.split(';')) {
    final at = part.lastIndexOf('=');
    if (at <= 0) continue;
    final v = int.tryParse(part.substring(at + 1).trim());
    if (v != null) out[part.substring(0, at).trim().toLowerCase()] = v;
  }
  return out;
}

/// Every album a thing belongs in — its source first, then at most one more.
///
/// [kind] 'photo' | 'video' | 'doc' (anything else has no albums).
/// [scores] what the picture shows and how sure (empty = not looked at yet:
/// then it is not put into a "what it shows" album at all);
/// [text] the words read inside it; [name] its title and file name.
/// [knownSource]: where it came from, when that was settled before (a
/// gallery photo BYTE took into its own folder keeps its album).
/// [fixed]: the album YOU chose for it ('' = BYTE decides, '-' = none).
List<String> placesFor({
  required String kind,
  required String path,
  required bool fromGallery,
  Map<String, int> scores = const {},
  String text = '',
  String name = '',
  String? knownSource,
  String fixed = '',
}) {
  if (kind == 'doc') {
    if (fixed.isNotEmpty) return fixed == '-' ? const [] : [fixed];
    final d = documentPlace(name: name, text: text);
    return [?d];
  }
  if (kind != 'photo' && kind != 'video') return const [];
  final source = knownSource ?? (fromGallery ? sourcePlace(path) : Places.saved);
  final out = <String>[source];
  // You said where it belongs: that stands.
  if (fixed.isNotEmpty) {
    if (fixed != '-' && fixed != source) out.add(fixed);
    return out;
  }
  if (kind == 'video') return out;

  var doc = documentPlace(name: name, text: text);
  // A screenshot of a chat is not an ID card or a certificate — only
  // payments, tickets and posters are kept from screenshots.
  if (source == Places.screenshots && doc != Places.bills && doc != Places.tickets && doc != Places.posters) doc = null;
  if (doc == null && (scores['receipt'] ?? 0) >= 80 && source != Places.screenshots) doc = Places.bills;
  if (doc != null) {
    out.add(doc);
    return out;
  }

  // What a picture shows is only said of your own photos — not of forwards,
  // downloads and screenshots.
  if (source != Places.camera && source != Places.saved) return out;
  final letters = text.replaceAll(RegExp(r'\s+'), '').length;
  final paperSeen = _paperLabels.any((l) => (scores[l] ?? 0) >= 70);
  if (letters >= 200 || (letters >= 40 && paperSeen)) {
    out.add(Places.papers);
    return out;
  }
  final shows = showsPlace(scores);
  if (shows != null) out.add(shows);
  return out;
}

/// The albums you can put a thing into by hand.
const choosablePlaces = <String>[
  Places.people, Places.nature, Places.food, Places.pets, Places.vehicles,
  Places.ids, Places.college, Places.certificates, Places.bills, Places.bank, Places.tickets, Places.posters, Places.papers,
];

/// The order of the albums in the strip (smaller = further left). Albums
/// named after a folder BYTE does not know come last.
int placeRank(String place) => switch (place) {
      Places.camera => 0,
      Places.saved => 1,
      Places.people => 10,
      Places.nature => 11,
      Places.food => 12,
      Places.pets => 13,
      Places.vehicles => 14,
      Places.ids => 20,
      Places.college => 21,
      Places.certificates => 22,
      Places.bills => 23,
      Places.bank => 24,
      Places.tickets => 25,
      Places.papers => 26,
      Places.posters => 27,
      Places.screenshots => 40,
      Places.screenRecordings => 41,
      Places.whatsapp => 42,
      Places.telegram => 43,
      Places.instagram => 44,
      Places.snapchat => 45,
      Places.facebook => 46,
      Places.downloads => 47,
      _ => 60,
    };

/// Albums for what a picture shows need a few pictures before they are
/// worth a card; the others show as soon as they have one.
int placeMinimum(String place) => switch (place) {
      Places.people || Places.nature || Places.food || Places.pets || Places.vehicles || Places.papers || Places.posters => 3,
      _ => 1,
    };
