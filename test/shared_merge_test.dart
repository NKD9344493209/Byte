import 'package:byte/features/friends/shared_merge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('what an item is known by', () {
    expect(itemKey('  Buy   Rice '), 'buy rice');
    expect(itemKey('Pay the fee ⏰2026-11-20 09:00'), 'pay the fee');
  });

  test('this phone: new, ticked and removed items are noticed', () {
    final (a, c1) = absorb('- [ ] Rice\n- [x] Milk', const {}, 100);
    expect(c1, isTrue);
    expect(a.keys, ['rice', 'milk']);
    expect(a['milk']!.done, isTrue);
    expect(a['rice']!.at, 100);

    // Nothing changed: nothing is stamped again.
    final (b, c2) = absorb('- [ ] Rice\n- [x] Milk', a, 200);
    expect(c2, isFalse);
    expect(b['rice']!.at, 100);

    // Rice ticked, Milk removed.
    final (c, c3) = absorb('- [x] Rice', b, 300);
    expect(c3, isTrue);
    expect(c['rice']!.done, isTrue);
    expect(c['rice']!.at, 300);
    expect(c['milk']!.gone, isTrue);
  });

  test('the later change wins, on both phones the same way', () {
    const mine = SharedItem(k: 'rice', text: 'Rice', done: false, gone: false, at: 100);
    const theirs = SharedItem(k: 'rice', text: 'Rice', done: true, gone: false, at: 200);
    final (m, changed) = mergeRemote({'rice': mine}, [theirs]);
    expect(changed, isTrue);
    expect(m['rice']!.done, isTrue);
    // The older word from there changes nothing here.
    final (n, again) = mergeRemote({'rice': theirs}, [mine]);
    expect(again, isFalse);
    expect(n['rice']!.done, isTrue);
  });

  test('the note is made to say what is known', () {
    const known = {
      'rice': SharedItem(k: 'rice', text: 'Rice', done: true, gone: false, at: 5),
      'milk': SharedItem(k: 'milk', text: 'Milk', done: false, gone: true, at: 5),
      'eggs': SharedItem(k: 'eggs', text: 'Eggs', done: false, gone: false, at: 5),
    };
    expect(applyTo('Shopping\n- [ ] Rice\n- [ ] Milk\n', known), 'Shopping\n- [x] Rice\n- [ ] Eggs');
    // Said again, it stays the same — and this phone sees nothing new in it.
    final body = applyTo('Shopping\n- [ ] Rice\n- [ ] Milk\n', known);
    expect(applyTo(body, known), body);
    expect(absorb(body, known, 9).$2, isFalse);
  });

  test('a change made here beats what it changes, even with a slow clock', () {
    // The friend ticked Rice at 5000 by their clock; this phone's clock says 1000.
    const known = {'rice': SharedItem(k: 'rice', text: 'Rice', done: true, gone: false, at: 5000)};
    final (mine, changed) = absorb('- [ ] Rice', known, 1000);
    expect(changed, isTrue);
    expect(mine['rice']!.done, isFalse);
    expect(mine['rice']!.at, 5001);
    // So the friend's older word does not undo it.
    expect(mergeRemote(mine, known.values).$2, isFalse);
  });

  test('removed items are forgotten after 30 days', () {
    const day = 24 * 60 * 60 * 1000;
    const known = {
      'a': SharedItem(k: 'a', text: 'A', done: false, gone: true, at: 0),
      'b': SharedItem(k: 'b', text: 'B', done: false, gone: true, at: 20 * day),
      'c': SharedItem(k: 'c', text: 'C', done: false, gone: false, at: 0),
    };
    expect(forgetOld(known, 31 * day).keys, ['b', 'c']);
  });
}
