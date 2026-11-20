import 'package:byte/features/notes/checklist.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const body = 'Shopping\n- [ ] Rice\n  - [ ] Basmati\n  - [x] Ponni\n- [x] Milk\nlast line';

  group('parse and write', () {
    test('tasks, sub-tasks and ordinary lines', () {
      final l = parseLines(body);
      expect(l.length, 6);
      expect(l[0].isTask, isFalse);
      expect(l[1].isTask && l[1].level == 0 && !l[1].done && l[1].text == 'Rice', isTrue);
      expect(l[2].level, 1);
      expect(l[3].done, isTrue);
      expect(l[4].level, 0);
      expect(l[5].text, 'last line');
    });

    test('what is written reads back the same', () {
      expect(writeLines(parseLines(body)), body);
    });

    test('an indented line with no task above it is just a task', () {
      expect(parseLines('  - [ ] alone').single.level, 0);
      expect(parseLines('- [ ] a\n\n  - [ ] b')[2].level, 0);
    });

    test('isChecklist and progress', () {
      expect(isChecklist(body), isTrue);
      expect(isChecklist('just words\n- not a task'), isFalse);
      expect(checklistProgress(body), (2, 4));
      expect(checklistProgress(''), (0, 0));
    });
  });

  group('ticking', () {
    test('ticking a task ticks its sub-tasks', () {
      expect(setTaskDone(body, 0), 'Shopping\n- [x] Rice\n  - [x] Basmati\n  - [x] Ponni\n- [x] Milk\nlast line');
    });

    test('the last open sub-task ticks the task above; unticking one unticks it', () {
      final allDone = setTaskDone(body, 1);
      expect(allDone, 'Shopping\n- [x] Rice\n  - [x] Basmati\n  - [x] Ponni\n- [x] Milk\nlast line');
      expect(setTaskDone(allDone, 2), 'Shopping\n- [ ] Rice\n  - [x] Basmati\n  - [ ] Ponni\n- [x] Milk\nlast line');
    });

    test('done: true never unticks; a wrong number changes nothing', () {
      expect(setTaskDone(body, 3, done: true), body);
      expect(setTaskDone(body, 9), body);
    });
  });

  group('adding and removing', () {
    test('a task goes to the end, below the last one', () {
      expect(addTask('- [ ] a\n\n', 'b'), '- [ ] a\n- [ ] b');
      expect(addTask('', 'first'), '- [ ] first');
      expect(addTask('- [ ] a', '   '), '- [ ] a');
    });

    test('a sub-task goes under its task and reopens it', () {
      expect(addTask('- [x] a\n- [ ] b', 'a1', underTask: 0), '- [ ] a\n  - [ ] a1\n- [ ] b');
      // asked under a sub-task → same parent, after the last sub-task
      expect(addTask('- [ ] a\n  - [ ] a1\n- [ ] b', 'a2', underTask: 1), '- [ ] a\n  - [ ] a1\n  - [ ] a2\n- [ ] b');
    });

    test('rename and remove (a task takes its sub-tasks along)', () {
      expect(renameTask('- [x] a', 0, 'b'), '- [x] b');
      expect(removeTask(body, 0), 'Shopping\n- [x] Milk\nlast line');
      expect(removeTask(body, 1), 'Shopping\n- [ ] Rice\n  - [x] Ponni\n- [x] Milk\nlast line');
    });
  });

  group('from speech and from text', () {
    test('one sentence becomes several tasks', () {
      expect(tasksFromSpeech('buy rice, call amma and then pay the fee.'), ['Buy rice', 'Call amma', 'Pay the fee']);
      expect(tasksFromSpeech('submit the record\nand print the hall ticket'), ['Submit the record', 'Print the hall ticket']);
      expect(tasksFromSpeech('  '), isEmpty);
      expect(tasksFromTyped('milk, eggs;bread\n butter '), ['milk', 'eggs', 'bread', 'butter']);
      expect(tasksFromTyped('Call Dr. Rao'), ['Call Dr. Rao']);
      expect(tasksFromTyped(' , '), isEmpty);
    });

    test('plain lines become tasks; tasks stay', () {
      expect(toChecklist('rice\n\n- [x] milk\n  eggs'), '- [ ] rice\n- [x] milk\n- [ ] eggs');
    });

    test('open tasks keep their numbers', () {
      expect(openTasks(body), [(0, 'Rice', 0), (1, 'Basmati', 1)]);
    });
  });

  group('what lists show', () {
    test('a task line without its mark', () {
      expect(plainLine('- [ ] Rice'), 'Rice');
      expect(plainLine('  - [x] Ponni'), 'Ponni');
      expect(plainLine('  plain words '), 'plain words');
    });

    test('preview of a checklist and of a plain note', () {
      expect(notePreview(body), '2 of 4 done · Rice, Basmati');
      expect(notePreview('- [x] a\n- [x] b'), 'All 2 done');
      expect(notePreview('one\n\ntwo'), 'one two');
      expect(notePreview('one\n\ntwo', skipFirst: true), 'two');
      expect(notePreview(''), '');
    });

    test('pinned items use the same numbers as ticking', () {
      final items = pinItems(body);
      expect(items.length, 4);
      expect(items[1], {'i': 1, 'text': 'Basmati', 'level': 1, 'done': false});
      // Ticking number 1 ticks exactly that one.
      expect(pinItems(setTaskDone(body, 1, done: true))[1]['done'], isTrue);
    });
  });

  test('an item added under a heading goes below that section', () {
    const week = 'Monday\n- [ ] Gym\nTuesday';
    expect(addTaskUnderLine(week, 0, 'Call amma'), 'Monday\n- [ ] Gym\n- [ ] Call amma\nTuesday');
    expect(addTaskUnderLine(week, 2, 'Fees'), 'Monday\n- [ ] Gym\nTuesday\n- [ ] Fees');
    expect(addTaskUnderLine(week, 9, 'x'), week);
  });

  group('reminders and repeating', () {
    const fee = 'Pay the fee ⏰2026-11-20 09:00';

    test('the mark at the end of a task', () {
      expect(dueOf(fee), DateTime(2026, 11, 20, 9));
      expect(plainTask(fee), 'Pay the fee');
      expect(dueOf('Pay the fee'), isNull);
      expect(withDue('Pay the fee', DateTime(2026, 11, 20, 9)), fee);
      expect(withDue(fee, null), 'Pay the fee');
    });

    test('said in words', () {
      expect(dueLabel(DateTime(2026, 11, 20, 9), now: DateTime(2026, 11, 19, 21)), 'Tomorrow, 9:00 am');
      expect(dueLabel(DateTime(2026, 11, 19, 18), now: DateTime(2026, 11, 19, 10)), 'Today, 6:00 pm');
    });

    test('set on a task; what people see never shows the mark', () {
      final b = setTaskDue('- [ ] Rice\n- [x] Milk', 0, DateTime(2026, 11, 20, 9));
      expect(b, '- [ ] Rice ⏰2026-11-20 09:00\n- [x] Milk');
      expect(remindersIn(b).single.index, 0);
      expect(openTasks(b).single.$2, 'Rice');
      expect(pinItems(b).first['text'], 'Rice');
      expect(setTaskDue(b, 0, null), '- [ ] Rice\n- [x] Milk');
    });

    test('a repeating list starts again, and a passed reminder moves on', () {
      expect(
        untickAll('- [x] Rice ⏰2026-11-18 09:00\n- [x] Milk', every: const Duration(days: 1), now: DateTime(2026, 11, 19, 21)),
        '- [ ] Rice ⏰2026-11-20 09:00\n- [ ] Milk',
      );
    });
  });
}
