import 'package:byte/features/voice/voice_command.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseVoice', () {
    test('find', () {
      expect(parseVoice('find my Aadhaar'), const VoiceCommand(VoiceKind.find, 'Aadhaar'));
      expect(parseVoice('Show me the hall ticket.'), const VoiceCommand(VoiceKind.find, 'hall ticket'));
      expect(parseVoice('where is my passport photo'), const VoiceCommand(VoiceKind.find, 'passport'));
      expect(parseVoice('search for electricity bill'), const VoiceCommand(VoiceKind.find, 'electricity bill'));
      expect(parseVoice('find my aadhaar card photo please'), const VoiceCommand(VoiceKind.find, 'aadhaar'));
    });

    test('plain words are a search too', () {
      expect(parseVoice('semester timetable'), const VoiceCommand(VoiceKind.find, 'semester timetable'));
      expect(parseVoice('photo'), const VoiceCommand(VoiceKind.find, 'photo'));
    });

    test('a note', () {
      expect(parseVoice('note buy milk tomorrow'), const VoiceCommand(VoiceKind.note, 'Buy milk tomorrow'));
      expect(parseVoice('Take a note that the locker is 214'), const VoiceCommand(VoiceKind.note, 'The locker is 214'));
      expect(parseVoice('remember, call amma at six'), const VoiceCommand(VoiceKind.note, 'Call amma at six'));
      expect(parseVoice('save a note: fee due on friday'), const VoiceCommand(VoiceKind.note, 'Fee due on friday'));
    });

    test('nothing said', () {
      expect(parseVoice('   '), const VoiceCommand(VoiceKind.none, ''));
      expect(parseVoice('.'), const VoiceCommand(VoiceKind.none, ''));
    });
  });

  group('voiceName', () {
    test('takes the name out of the sentence', () {
      expect(voiceName('save this as hostel fee receipt'), 'Hostel fee receipt');
      expect(voiceName('name it Ooty trip'), 'Ooty trip');
      expect(voiceName('call this bike insurance.'), 'Bike insurance');
      expect(voiceName('rename to mark sheet'), 'Mark sheet');
    });

    test('just the name', () {
      expect(voiceName('college id'), 'College id');
    });
  });
}
