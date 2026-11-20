import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'vault_key.dart';

/// The vault database: SQLite encrypted with SQLite3 Multiple Ciphers
/// (AES-256-class cipher, key never stored with the file).
/// The key comes from [VaultKey]; the file is unreadable without it.
class AppDb {
  AppDb._();
  static final AppDb instance = AppDb._();

  Database? _db;
  Database get db {
    final d = _db;
    if (d == null) {
      throw StateError('AppDb.open() must be called before use');
    }
    return d;
  }

  static const _version = 18;
  static const plainName = 'byte_vault.db'; // pre-encryption file (migrated)
  static const vaultName = 'byte_vault.enc.db';

  String? _path;
  String? get path => _path;

  Future<void> open() async {
    if (_db != null) return;
    final dir = await getApplicationSupportDirectory();
    final encPath = p.join(dir.path, vaultName);
    final plainPath = p.join(dir.path, plainName);
    final key = await VaultKey.get();

    _db = await _openEncrypted(encPath, key);
    _path = encPath;

    await ensureStorageSchema();
    await _purgeDeleted();

    // One-time migration of the old unencrypted vault.
    if (await File(plainPath).exists()) {
      try {
        await _migrateFromPlain(plainPath);
        await File(plainPath).rename('$plainPath.migrated');
        debugPrint('[vault] migrated plain DB into encrypted vault');
      } catch (e, st) {
        debugPrint('[vault] migration failed: $e\n$st');
      }
    }
  }

  Future<Database> _openEncrypted(String path, String hexKey) {
    return openDatabase(
      path,
      version: _version,
      onConfigure: (db) async {
        // Raw 256-bit key (SQLite3 Multiple Ciphers: PRAGMA hexkey).
        await db.rawQuery("PRAGMA hexkey = '$hexKey'");
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: _createSchema,
      onUpgrade: (db, oldV, newV) async {
        if (oldV < 2) {
          await db.execute(
            "ALTER TABLE audio ADD COLUMN transcript_status TEXT NOT NULL DEFAULT 'pending'",
          );
        }
        if (oldV < 3) {
          await _createTrackerTables(db);
        }
        if (oldV < 4) {
          await db.execute(
            'ALTER TABLE trackers ADD COLUMN escalate INTEGER NOT NULL DEFAULT 1',
          );
          await _createNudgeTables(db);
        }
        if (oldV < 5) {
          await db.execute('ALTER TABLE trackers ADD COLUMN verify_kind TEXT');
          await db.execute('ALTER TABLE trackers ADD COLUMN verify_ref TEXT');
        }
        if (oldV < 6) {
          await _createFilesTable(db);
        }
        if (oldV < 7) {
          await db.execute('ALTER TABLE items ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0');
          // Vision arrived: re-index photos/videos so they get OCR + labels.
          await db.execute(
            "UPDATE files SET index_status = 'pending' WHERE kind IN ('photo','video')",
          );
        }
        if (oldV < 8) {
          await _createChatTable(db);
        }
        if (oldV < 9) {
          await _createWealthTables(db);
        }
        if (oldV < 10) {
          await _createRewardTables(db);
        }
        if (oldV < 11) {
          await _createMotivationTable(db);
        }
        if (oldV < 12) {
          // Tables created earlier in this same upgrade already carry the
          // v12 columns (the CREATE statements are current) — only ALTER
          // tables that pre-date this version.
          if (oldV >= 3) {
            await db.execute('ALTER TABLE trackers ADD COLUMN coach INTEGER NOT NULL DEFAULT 0');
            await db.execute("ALTER TABLE trackers ADD COLUMN purpose TEXT NOT NULL DEFAULT ''");
          }
          if (oldV >= 8) {
            await db.execute("ALTER TABLE chat_messages ADD COLUMN tracker_id TEXT NOT NULL DEFAULT ''");
          }
          await _createPlanTables(db);
        }
        if (oldV < 13) {
          await _createWatchTables(db);
        }
        if (oldV < 14) {
          await _createEventTables(db);
        }
        if (oldV < 15 && oldV >= 13) {
          // Reply drafts on caught messages (v13 created inbox_events without them).
          for (final c in ['key TEXT NOT NULL DEFAULT \'\'', 'can_reply INTEGER NOT NULL DEFAULT 0', 'draft TEXT NOT NULL DEFAULT \'\'', 'reply_status TEXT NOT NULL DEFAULT \'\'']) {
            await db.execute('ALTER TABLE inbox_events ADD COLUMN $c');
          }
        }
        if (oldV < 16) {
          await _createCollectionTables(db);
          await _createReminderTables(db);
          await _createCloudTables(db);
        }
        if (oldV < 17) {
          await _createLifePlanTables(db);
        }
        if (oldV < 18 && oldV >= 17) {
          // Money diary: which pocket (personal / shared / …) and entry kind
          // (spend | balance | income). v17 created spend without them.
          await db.execute("ALTER TABLE spend ADD COLUMN pocket TEXT NOT NULL DEFAULT 'personal'");
          await db.execute("ALTER TABLE spend ADD COLUMN kind TEXT NOT NULL DEFAULT 'spend'");
        }
      },
    );
  }

  /// Copies every row of the old plaintext DB into the encrypted one.
  Future<void> _migrateFromPlain(String plainPath) async {
    final old = await openDatabase(plainPath, readOnly: true);
    try {
      final items = await old.query('items');
      final audio = await old.query('audio');
      final history = await old.query('item_history');
      await db.transaction((txn) async {
        for (final r in items) {
          await txn.insert('items', r, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
        for (final r in audio) {
          final row = Map<String, Object?>.from(r);
          row.putIfAbsent('transcript_status', () => 'pending');
          await txn.insert('audio', row, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
        for (final r in history) {
          final row = Map<String, Object?>.from(r)..remove('id');
          await txn.insert('item_history', row);
        }
      });
    } finally {
      await old.close();
    }
  }

  Future<void> _createSchema(Database db, int version) async {
    await db.execute('''
      CREATE TABLE items (
        id          TEXT PRIMARY KEY,
        type        TEXT NOT NULL,            -- note | audio | link | doc
        title       TEXT NOT NULL DEFAULT '',
        body        TEXT NOT NULL DEFAULT '',
        tags        TEXT NOT NULL DEFAULT '', -- comma separated
        sensitivity INTEGER NOT NULL DEFAULT 0,
        source      TEXT NOT NULL DEFAULT 'manual',
        created_at  INTEGER NOT NULL,
        updated_at  INTEGER NOT NULL,
        deleted_at  INTEGER,
        pinned      INTEGER NOT NULL DEFAULT 0   -- on the home-screen sticky board
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_items_updated ON items(updated_at DESC)',
    );
    await db.execute(
      'CREATE INDEX idx_items_type ON items(type)',
    );

    await db.execute('''
      CREATE TABLE audio (
        item_id        TEXT PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,
        path           TEXT NOT NULL,
        duration_ms    INTEGER NOT NULL DEFAULT 0,
        raw_transcript TEXT NOT NULL DEFAULT '',
        clean_text     TEXT NOT NULL DEFAULT '',
        transcript_status TEXT NOT NULL DEFAULT 'pending'
      )
    ''');

    await db.execute('''
      CREATE TABLE item_history (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        item_id    TEXT NOT NULL,
        title      TEXT NOT NULL,
        body       TEXT NOT NULL,
        saved_at   INTEGER NOT NULL
      )
    ''');

    await _createTrackerTables(db);
    await _createFilesTable(db);
    await _createChatTable(db);
    await _createWealthTables(db);
    await _createRewardTables(db);
    await _createMotivationTable(db);
    await _createPlanTables(db);
    await _createWatchTables(db);
    await _createEventTables(db);
    await _createCollectionTables(db);
    await _createReminderTables(db);
    await _createCloudTables(db);
    await _createLifePlanTables(db);
  }

  /// v17: BYTE's Day — the adaptive daily plan, what got done, monthly
  /// measurements, the grocery list and the spending log.
  Future<void> _createLifePlanTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS plan_days (
        day        TEXT PRIMARY KEY,                 -- yyyy-MM-dd
        json       TEXT NOT NULL,
        built_at   INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS plan_log (
        day        TEXT NOT NULL,
        task_id    TEXT NOT NULL,
        status     TEXT NOT NULL,                    -- done | skipped | no | later
        at         INTEGER NOT NULL,
        note       TEXT NOT NULL DEFAULT '',
        PRIMARY KEY (day, task_id)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS plan_measure (
        month      TEXT PRIMARY KEY,                 -- yyyy-MM
        json       TEXT NOT NULL,
        at         INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS grocery (
        id         TEXT PRIMARY KEY,
        name       TEXT NOT NULL,
        qty        REAL NOT NULL DEFAULT 1,
        unit       TEXT NOT NULL DEFAULT '',
        every_days INTEGER NOT NULL DEFAULT 7,       -- 0 = one-time
        category   TEXT NOT NULL DEFAULT '',
        last_bought INTEGER,
        custom     INTEGER NOT NULL DEFAULT 0,       -- 1 = user-added (not from the plan)
        active     INTEGER NOT NULL DEFAULT 1
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS spend (
        id         TEXT PRIMARY KEY,
        amount     REAL NOT NULL,
        category   TEXT NOT NULL DEFAULT 'other',    -- food | treats | transport | college | health | phone | other
        note       TEXT NOT NULL DEFAULT '',
        at         INTEGER NOT NULL,
        pocket     TEXT NOT NULL DEFAULT 'personal', -- v18: personal | shared | <your own>
        kind       TEXT NOT NULL DEFAULT 'spend'     -- v18: spend | balance | income
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_spend_at ON spend(at)');
  }

  /// v16: Collections — playlists / "watch later" for anything in the vault
  /// (recordings, photos, videos, notes, files). One item can be in many.
  Future<void> _createCollectionTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS collections (
        id          TEXT PRIMARY KEY,
        name        TEXT NOT NULL,
        kind        TEXT NOT NULL DEFAULT 'custom', -- custom | later (built-in "Watch later")
        icon        TEXT NOT NULL DEFAULT '',
        created_at  INTEGER NOT NULL,
        sort_order  INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS collection_items (
        collection_id TEXT NOT NULL,
        item_id       TEXT NOT NULL,
        added_at      INTEGER NOT NULL,
        position      INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (collection_id, item_id)
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_coll_items_item ON collection_items(item_id)');
  }

  /// v16: BYTE's own reminders ("remind me to drink water every 2 hours") —
  /// real alarms: sound when the phone is loud, vibration + full page when silent.
  Future<void> _createReminderTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS reminders (
        id            TEXT PRIMARY KEY,
        text          TEXT NOT NULL,
        at            INTEGER NOT NULL,              -- next fire (ms)
        every_min     INTEGER NOT NULL DEFAULT 0,    -- 0 = once; else repeat every N minutes
        until_hhmm    TEXT NOT NULL DEFAULT '',      -- repeating: stop for the day after this time ('' = quiet start)
        from_hhmm     TEXT NOT NULL DEFAULT '',      -- repeating: don't fire before this time
        daily         INTEGER NOT NULL DEFAULT 0,    -- 1 = every day at the same time
        status        TEXT NOT NULL DEFAULT 'active',-- active | done | cancelled | paused
        source        TEXT NOT NULL DEFAULT 'voice',
        created_at    INTEGER NOT NULL,
        last_fired    INTEGER,
        fired_count   INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_reminders_at ON reminders(status, at)');
  }

  /// v16: what has already been copied to the cloud (Google Drive) and under
  /// which file id, so a sync only uploads what changed.
  Future<void> _createCloudTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS cloud_files (
        rel_path    TEXT PRIMARY KEY,                -- audio/x.wav | files/x.jpg | db/byte_vault.enc.db
        remote_id   TEXT NOT NULL,
        size        INTEGER NOT NULL,
        mtime       INTEGER NOT NULL,
        uploaded_at INTEGER NOT NULL
      )
    ''');
  }

  /// v14: dated events ("meeting on the 28th") with their own reminders,
  /// and audio playlists.
  Future<void> _createEventTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS events (
        id          TEXT PRIMARY KEY,
        title       TEXT NOT NULL,
        at          INTEGER NOT NULL,                -- start (ms); 09:00 when has_time = 0
        has_time    INTEGER NOT NULL DEFAULT 0,
        notes       TEXT NOT NULL DEFAULT '',
        source      TEXT NOT NULL DEFAULT 'voice',   -- voice | manual | message
        created_at  INTEGER NOT NULL,
        done        INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_events_at ON events(at)');
  }

  /// v13: Watches (things BYTE keeps checking on the web) and the important
  /// messages it caught from other apps' notifications.
  Future<void> _createWatchTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS watches (
        id          TEXT PRIMARY KEY,
        condition   TEXT NOT NULL,                 -- "tickets for X open in Coimbatore"
        kind        TEXT NOT NULL DEFAULT 'general',
        interval_h  INTEGER NOT NULL DEFAULT 6,
        status      TEXT NOT NULL DEFAULT 'pending', -- pending | found | stopped
        last_check  INTEGER,
        last_note   TEXT NOT NULL DEFAULT '',
        url         TEXT NOT NULL DEFAULT '',
        checks      INTEGER NOT NULL DEFAULT 0,
        created_at  INTEGER NOT NULL,
        found_at    INTEGER,
        seen        INTEGER NOT NULL DEFAULT 0       -- found + shown on Today
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS inbox_events (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        pkg         TEXT NOT NULL,                 -- com.whatsapp, com.google.android.gm …
        app         TEXT NOT NULL DEFAULT '',
        who         TEXT NOT NULL DEFAULT '',
        text        TEXT NOT NULL DEFAULT '',
        rule        TEXT NOT NULL DEFAULT '',      -- which person/keyword matched
        at          INTEGER NOT NULL,
        seen        INTEGER NOT NULL DEFAULT 0,
        key         TEXT NOT NULL DEFAULT '',      -- v15: the notification key (for inline reply)
        can_reply   INTEGER NOT NULL DEFAULT 0,    -- v15: the app offered an inline Reply action
        draft       TEXT NOT NULL DEFAULT '',      -- v15: BYTE's suggested reply
        reply_status TEXT NOT NULL DEFAULT ''      -- v15: '' | draft | sent | auto | declined | failed
      )
    ''');
  }

  /// v12: Coach — a plan behind a tracker (from a PPT/PDF or the AI) and the
  /// day-by-day schedule BYTE keeps balanced.
  Future<void> _createPlanTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS plans (
        id             TEXT PRIMARY KEY,
        tracker_id     TEXT NOT NULL,
        title          TEXT NOT NULL,
        goal           TEXT NOT NULL DEFAULT '',
        source_item_id TEXT NOT NULL DEFAULT '',   -- Library doc it came from
        cycle          TEXT NOT NULL DEFAULT 'rotate', -- rotate (gym groups repeat) | linear (syllabus, once through)
        created_at     INTEGER NOT NULL,
        updated_at     INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS plan_items (
        id        INTEGER PRIMARY KEY AUTOINCREMENT,
        plan_id   TEXT NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
        position  INTEGER NOT NULL DEFAULT 0,
        title     TEXT NOT NULL,
        detail    TEXT NOT NULL DEFAULT '',        -- how to do it
        dose      TEXT NOT NULL DEFAULT '',        -- "3 x 12", "20 min", "2 problems"
        grp       TEXT NOT NULL DEFAULT '',        -- "Legs", "Unit 3"
        minutes   INTEGER NOT NULL DEFAULT 10
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS plan_schedule (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        plan_id    TEXT NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
        item_id    INTEGER NOT NULL,
        day        TEXT NOT NULL,                  -- yyyy-MM-dd
        status     TEXT NOT NULL DEFAULT 'pending', -- pending | done | moved
        moved_from TEXT NOT NULL DEFAULT '',
        UNIQUE(plan_id, item_id, day)
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_sched_day ON plan_schedule(day)');
  }

  /// v11: your own motivation bank — lines BYTE says back to you by state.
  Future<void> _createMotivationTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS motivation (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        text       TEXT NOT NULL,
        author     TEXT NOT NULL DEFAULT '',
        state      TEXT NOT NULL DEFAULT 'any',    -- any | start | miss | win
        builtin    INTEGER NOT NULL DEFAULT 0,
        uses       INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      )
    ''');
  }

  /// v10: Rewards — rules tied to trackers, paid from a monthly envelope.
  Future<void> _createRewardTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS rewards (
        id          TEXT PRIMARY KEY,
        tracker_id  TEXT NOT NULL,
        rule        TEXT NOT NULL,                 -- streak | month_count | perfect_week
        threshold   INTEGER NOT NULL DEFAULT 7,
        amount      REAL NOT NULL DEFAULT 0,       -- rupees (0 = treat only)
        treat       TEXT NOT NULL DEFAULT '',      -- "Biryani", "Movie night"
        repeat      INTEGER NOT NULL DEFAULT 1,    -- 1 = every multiple (7, 14, 21…)
        created_at  INTEGER NOT NULL,
        archived_at INTEGER
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS reward_log (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        reward_id   TEXT NOT NULL,
        tracker_id  TEXT NOT NULL,
        milestone   TEXT NOT NULL,                 -- "streak:14", "month:2026-10:20", "week:2026-W42"
        amount      REAL NOT NULL DEFAULT 0,       -- actually paid (after the envelope)
        asked       REAL NOT NULL DEFAULT 0,       -- what the rule promised
        treat       TEXT NOT NULL DEFAULT '',
        month       TEXT NOT NULL,                 -- yyyy-MM it was paid from
        earned_at   INTEGER NOT NULL,
        claimed_at  INTEGER,
        seen        INTEGER NOT NULL DEFAULT 0,    -- gift-box moment shown
        UNIQUE(reward_id, milestone)
      )
    ''');
  }

  /// v9: Wealth — the locked compartment. Instruments + a price history you
  /// type in (gold per gram, MF NAV). Exact maths lives in Dart.
  Future<void> _createWealthTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS wealth_instruments (
        id            TEXT PRIMARY KEY,
        kind          TEXT NOT NULL,                -- fd|rd|ppf|gold|mf|stock|cash|loan|subscription
        name          TEXT NOT NULL,
        bank          TEXT NOT NULL DEFAULT '',
        amount        REAL NOT NULL DEFAULT 0,      -- principal / instalment / cash / loan principal / monthly cost
        rate          REAL NOT NULL DEFAULT 0,      -- % per year
        start_date    TEXT NOT NULL DEFAULT '',     -- yyyy-MM-dd
        tenure_months INTEGER NOT NULL DEFAULT 0,
        compounding   TEXT NOT NULL DEFAULT 'quarterly', -- simple|monthly|quarterly|yearly
        units         REAL NOT NULL DEFAULT 0,      -- grams / MF units / shares
        buy_price     REAL NOT NULL DEFAULT 0,      -- per unit, what you paid
        price_asset   TEXT NOT NULL DEFAULT '',     -- key into wealth_prices (gold22, gold24, or the instrument id)
        note          TEXT NOT NULL DEFAULT '',
        created_at    INTEGER NOT NULL,
        updated_at    INTEGER NOT NULL,
        deleted_at    INTEGER
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS wealth_prices (
        asset  TEXT NOT NULL,
        date   TEXT NOT NULL,                       -- yyyy-MM-dd
        price  REAL NOT NULL,
        PRIMARY KEY (asset, date)
      )
    ''');
  }

  /// v8: Ask BYTE — the conversation, plus what was sent to the AI for each
  /// answer (the privacy log).
  Future<void> _createChatTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS chat_messages (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        role       TEXT NOT NULL,                 -- user | byte
        text       TEXT NOT NULL,
        sources    TEXT NOT NULL DEFAULT '[]',    -- JSON: [{id,type,title}]
        sent       TEXT NOT NULL DEFAULT '',      -- exact context sent to the AI
        provider   TEXT NOT NULL DEFAULT '',      -- claude | openai | gemini | local
        created_at INTEGER NOT NULL,
        tracker_id TEXT NOT NULL DEFAULT ''       -- v12: '' = Ask BYTE, else that tracker's coach chat
      )
    ''');
  }


  /// v6: Library — photos, videos, documents, links (one row per item).
  Future<void> _createFilesTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS files (
        item_id      TEXT PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,
        kind         TEXT NOT NULL,                 -- photo | video | doc | link
        path         TEXT NOT NULL DEFAULT '',      -- local copy ('' for links)
        url          TEXT NOT NULL DEFAULT '',
        mime         TEXT NOT NULL DEFAULT '',
        size         INTEGER NOT NULL DEFAULT 0,
        thumb        TEXT NOT NULL DEFAULT '',
        text         TEXT NOT NULL DEFAULT '',      -- OCR / document text / page info
        labels       TEXT NOT NULL DEFAULT '',      -- AI labels, comma separated
        index_status TEXT NOT NULL DEFAULT 'pending'
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_files_kind ON files(kind)');
  }

  /// v3: trackers. One row per habit/measurement, one row per log entry.
  Future<void> _createTrackerTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS trackers (
        id              TEXT PRIMARY KEY,
        name            TEXT NOT NULL,
        kind            TEXT NOT NULL,              -- check | count | value
        unit            TEXT NOT NULL DEFAULT '',
        target          REAL,
        lower_is_better INTEGER NOT NULL DEFAULT 0,
        days            INTEGER NOT NULL DEFAULT 127, -- bitmask Mon=1 .. Sun=64
        remind_at       TEXT,                       -- 'HH:mm' local
        icon            TEXT NOT NULL DEFAULT '',
        private         INTEGER NOT NULL DEFAULT 0,
        sort_order      INTEGER NOT NULL DEFAULT 0,
        created_at      INTEGER NOT NULL,
        archived_at     INTEGER,
        escalate        INTEGER NOT NULL DEFAULT 1, -- follow-ups 1 h / 3 h later
        verify_kind     TEXT,                       -- 'leetcode' = auto-verified
        verify_ref      TEXT,                       -- e.g. LeetCode username
        coach           INTEGER NOT NULL DEFAULT 0, -- v12: BYTE plans + coaches this
        purpose         TEXT NOT NULL DEFAULT ''    -- v12: what the user wants BYTE to do
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS tracker_entries (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        tracker_id TEXT NOT NULL REFERENCES trackers(id) ON DELETE CASCADE,
        day        TEXT NOT NULL,                   -- yyyy-MM-dd local
        value      REAL NOT NULL DEFAULT 1,
        note       TEXT NOT NULL DEFAULT '',
        logged_at  INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_entries_tracker_day '
      'ON tracker_entries(tracker_id, day)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_entries_day ON tracker_entries(day)',
    );
    await _createNudgeTables(db);
  }

  /// v4: the nudge bank (user's own messages) and the log BYTE learns from.
  Future<void> _createNudgeTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS nudges (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        text       TEXT NOT NULL,
        stage      INTEGER NOT NULL DEFAULT 1,     -- 1 gentle, 2 firm, 3 harsh
        tracker_id TEXT,                           -- NULL = any tracker
        uses       INTEGER NOT NULL DEFAULT 0,
        wins       INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS nudge_log (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        tracker_id   TEXT NOT NULL,
        day          TEXT NOT NULL,
        stage        INTEGER NOT NULL,
        nudge_id     INTEGER NOT NULL DEFAULT 0,   -- 0 = built-in message
        planned_at   INTEGER NOT NULL,
        fired        INTEGER NOT NULL DEFAULT 0,
        response     TEXT,                         -- done | snooze | later
        responded_at INTEGER,
        UNIQUE(tracker_id, day, stage)
      )
    ''');
  }

  /// What the storage app added on top of schema v18. Done here, not as a
  /// numbered migration: every statement is safe to run again, so it also
  /// repairs a vault restored from an older backup. Runs at every open.
  /// Each step stands alone — one that fails does not hold back the others.
  Future<void> ensureStorageSchema() async {
    // Gallery (Round 2): "image:123" / "video:123" / "audio:123" = this row is
    // a photo that lives in the phone's own gallery, not a copy inside BYTE.
    await _step('files.media_key', () async {
      if (!await _hasColumn('files', 'media_key')) {
        await db.execute("ALTER TABLE files ADD COLUMN media_key TEXT NOT NULL DEFAULT ''");
      }
    });
    await _step('idx_files_media_key', () => db.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_files_media_key ON files(media_key) WHERE media_key != ''"));
    await _step('idx_items_created', () => db.execute('CREATE INDEX IF NOT EXISTS idx_items_created ON items(created_at DESC)'));
    // Gallery things deleted for good in BYTE: never bring them in again.
    await _step('gallery_skip', () => db.execute('CREATE TABLE IF NOT EXISTS gallery_skip (media_key TEXT PRIMARY KEY)'));
    // Every word BYTE has read anywhere — lets Search forgive a spelling slip.
    await _step('words', () => db.execute('CREATE TABLE IF NOT EXISTS words (word TEXT PRIMARY KEY) WITHOUT ROWID'));
    // Voice notes (Round 3): what BYTE heard → what you corrected it to.
    await _step('heard_fixes', () => db.execute('CREATE TABLE IF NOT EXISTS heard_fixes (heard TEXT PRIMARY KEY, meant TEXT NOT NULL, at INTEGER NOT NULL DEFAULT 0)'));
    // Private space (Round 4): 1 = this item (or folder) is shown only inside
    // the private space, behind its own PIN.
    await _step('items.private', () async {
      if (!await _hasColumn('items', 'private')) {
        await db.execute('ALTER TABLE items ADD COLUMN private INTEGER NOT NULL DEFAULT 0');
      }
    });
    await _step('collections.private', () async {
      if (!await _hasColumn('collections', 'private')) {
        await db.execute('ALTER TABLE collections ADD COLUMN private INTEGER NOT NULL DEFAULT 0');
      }
    });
    await _step('idx_items_private1', () => db.execute('CREATE INDEX IF NOT EXISTS idx_items_private1 ON items(private) WHERE private = 1'));
    // The private key, locked with the PIN (and with the recovery key), and
    // the plain Drive copies that must still go to Drive's Trash.
    await _step('private_space', () => db.execute('CREATE TABLE IF NOT EXISTS private_space (k TEXT PRIMARY KEY, v TEXT NOT NULL)'));
    await _step('private_trash', () => db.execute('CREATE TABLE IF NOT EXISTS private_trash (remote_id TEXT PRIMARY KEY)'));
    // Round 5. "Delete by itself on this day" (empty = never), and the list
    // of what was done lately, each with what is needed to undo it.
    await _step('items.expires_at', () async {
      if (!await _hasColumn('items', 'expires_at')) {
        await db.execute('ALTER TABLE items ADD COLUMN expires_at INTEGER');
      }
    });
    await _step('idx_items_expires', () => db.execute('CREATE INDEX IF NOT EXISTS idx_items_expires ON items(expires_at) WHERE expires_at IS NOT NULL'));
    await _step('activity', () => db.execute('''
      CREATE TABLE IF NOT EXISTS activity (
        id      INTEGER PRIMARY KEY AUTOINCREMENT,
        at      INTEGER NOT NULL,
        kind    TEXT NOT NULL,
        summary TEXT NOT NULL,
        undo    TEXT NOT NULL DEFAULT '',
        undone  INTEGER NOT NULL DEFAULT 0
      )
    '''));
    // Round 5b. Albums BYTE keeps by itself: where each photo came from
    // (files.src: Camera, Screenshots, WhatsApp…) and every album it is in
    // (item_places). files.sorted says how far the sorter got with a file.
    await _step('files.sorted', () async {
      if (!await _hasColumn('files', 'sorted')) {
        await db.execute('ALTER TABLE files ADD COLUMN sorted INTEGER NOT NULL DEFAULT 0');
      }
    });
    await _step('files.src', () async {
      if (!await _hasColumn('files', 'src')) {
        await db.execute("ALTER TABLE files ADD COLUMN src TEXT NOT NULL DEFAULT ''");
      }
    });
    // What the phone's picture recognition saw in a photo and how sure it
    // was ("food=91;dish=74"; "-" = looked, nothing seen) — the albums use it.
    await _step('files.seen', () async {
      if (!await _hasColumn('files', 'seen')) {
        await db.execute("ALTER TABLE files ADD COLUMN seen TEXT NOT NULL DEFAULT ''");
      }
    });
    // The album YOU chose for a thing ('' = BYTE decides, '-' = none).
    await _step('files.fixed', () async {
      if (!await _hasColumn('files', 'fixed')) {
        await db.execute("ALTER TABLE files ADD COLUMN fixed TEXT NOT NULL DEFAULT ''");
      }
    });
    await _step('item_places', () => db.execute('CREATE TABLE IF NOT EXISTS item_places (item_id TEXT NOT NULL, place TEXT NOT NULL, PRIMARY KEY (item_id, place)) WITHOUT ROWID'));
    await _step('idx_item_places_place', () => db.execute('CREATE INDEX IF NOT EXISTS idx_item_places_place ON item_places(place)'));
    // Round 6. What you shared with a link (a folder in your Google Drive).
    await _step('shares', () => db.execute('''
      CREATE TABLE IF NOT EXISTS shares (
        id         TEXT PRIMARY KEY,
        name       TEXT NOT NULL,
        folder_id  TEXT NOT NULL,
        link       TEXT NOT NULL,
        can_add    INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        expires_at INTEGER,
        count      INTEGER NOT NULL DEFAULT 0
      )
    '''));
    // Round 7. The document wallet: the papers that matter, each with the
    // day it stops being valid (empty = it does not run out).
    await _step('wallet', () => db.execute('''
      CREATE TABLE IF NOT EXISTS wallet (
        item_id    TEXT PRIMARY KEY,
        label      TEXT NOT NULL DEFAULT '',
        expires_at INTEGER,
        added_at   INTEGER NOT NULL
      )
    '''));
    await _repeatColumns();
    await _friendTables();
  }

  /// Friends and what is shared with them (see Friends).
  Future<void> _friendTables() async {
    // A friend: who, the box this phone writes for them, the box they write for us.
    await _step('friends', () => db.execute('''
      CREATE TABLE IF NOT EXISTS friends (
        id        TEXT PRIMARY KEY,
        name      TEXT NOT NULL DEFAULT '',
        my_box    TEXT NOT NULL DEFAULT '',
        their_box TEXT NOT NULL DEFAULT '',
        added_at  INTEGER NOT NULL DEFAULT 0
      )
    '''));
    // An invite that was sent and not answered yet: the box made for it.
    await _step('friend_invites', () => db.execute('CREATE TABLE IF NOT EXISTS friend_invites (box TEXT PRIMARY KEY, made_at INTEGER NOT NULL DEFAULT 0)'));
    // A checklist shared with a friend: the list's id (the same on both
    // phones), the note it is on this phone, and whether sharing has stopped.
    await _step('shared_lists', () => db.execute('''
      CREATE TABLE IF NOT EXISTS shared_lists (
        list_id   TEXT PRIMARY KEY,
        friend_id TEXT NOT NULL,
        note_id   TEXT NOT NULL,
        title     TEXT NOT NULL DEFAULT '',
        closed    INTEGER NOT NULL DEFAULT 0
      )
    '''));
    // An album shared with a friend: the album's id (the same on both
    // phones), and each photo in it — a file in the Drive of whoever added it
    // ("mine": this phone added it; share_id: the link of mine it belongs to).
    await _step('shared_albums', () => db.execute('''
      CREATE TABLE IF NOT EXISTS shared_albums (
        album_id  TEXT PRIMARY KEY,
        friend_id TEXT NOT NULL,
        title     TEXT NOT NULL DEFAULT '',
        made_at   INTEGER NOT NULL DEFAULT 0
      )
    '''));
    await _step('shared_photos', () => db.execute('''
      CREATE TABLE IF NOT EXISTS shared_photos (
        album_id TEXT NOT NULL,
        k        TEXT NOT NULL,
        name     TEXT NOT NULL DEFAULT '',
        kind     TEXT NOT NULL DEFAULT 'photo',
        mine     INTEGER NOT NULL DEFAULT 0,
        share_id TEXT NOT NULL DEFAULT '',
        at       INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (album_id, k)
      ) WITHOUT ROWID
    '''));
    // Its items as both phones know them (see shared_merge.dart).
    await _step('shared_items', () => db.execute('''
      CREATE TABLE IF NOT EXISTS shared_items (
        list_id TEXT NOT NULL,
        k       TEXT NOT NULL,
        text    TEXT NOT NULL DEFAULT '',
        done    INTEGER NOT NULL DEFAULT 0,
        gone    INTEGER NOT NULL DEFAULT 0,
        at      INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (list_id, k)
      ) WITHOUT ROWID
    '''));
  }

  /// Lists that start again by themselves (see Repeats): how ('' | 'daily' |
  /// 'weekly'), and the round that was begun last.
  Future<void> _repeatColumns() async {
    await _step('items.repeat', () async {
      if (!await _hasColumn('items', 'repeat')) {
        await db.execute("ALTER TABLE items ADD COLUMN repeat TEXT NOT NULL DEFAULT ''");
      }
    });
    await _step('items.repeat_mark', () async {
      if (!await _hasColumn('items', 'repeat_mark')) {
        await db.execute("ALTER TABLE items ADD COLUMN repeat_mark TEXT NOT NULL DEFAULT ''");
      }
    });
  }

  Future<void> _step(String what, Future<void> Function() run) async {
    try {
      await run();
    } catch (e) {
      debugPrint('[vault] storage schema ($what): $e');
    }
  }

  Future<bool> _hasColumn(String table, String column) async {
    final rows = await db.rawQuery('PRAGMA table_info($table)');
    return rows.any((r) => r['name'] == column);
  }

  /// Things in the bin are kept 30 days, then removed for good (BYTE's own
  /// files included). Their Google Drive copies go to Drive's Trash the next
  /// time the upload worker runs (it notices the item is gone).
  Future<void> _purgeDeleted() async {
    try {
      final cutoff = DateTime.now().subtract(const Duration(days: 30)).millisecondsSinceEpoch;
      // Gallery photos whose 30 days are up: remember them, or the next look at
      // the gallery would bring them straight back.
      await db.rawInsert(
        "INSERT OR IGNORE INTO gallery_skip (media_key) SELECT f.media_key FROM files f JOIN items i ON i.id = f.item_id "
        "WHERE i.deleted_at IS NOT NULL AND i.deleted_at < ? AND f.media_key != ''",
        [cutoff],
      );
      final rows = await db.rawQuery(
        'SELECT i.id, a.path, f.path AS fpath, f.thumb AS fthumb FROM items i '
        'LEFT JOIN audio a ON a.item_id = i.id '
        'LEFT JOIN files f ON f.item_id = i.id '
        'WHERE i.deleted_at IS NOT NULL AND i.deleted_at < ?',
        [cutoff],
      );
      if (rows.isEmpty) return;
      // Only BYTE's own copies are ever deleted — never a file that lives
      // somewhere else on the phone and is merely listed in the vault.
      final own = (await getApplicationSupportDirectory()).path;
      for (final r in rows) {
        for (final key in const ['path', 'fpath', 'fthumb']) {
          final path = r[key] as String?;
          if (path == null || path.isEmpty || !p.isWithin(own, path)) continue;
          try {
            final f = File(path);
            if (await f.exists()) await f.delete();
          } catch (_) {}
        }
        await db.delete('item_history', where: 'item_id = ?', whereArgs: [r['id']]);
        await db.delete('collection_items', where: 'item_id = ?', whereArgs: [r['id']]);
        await db.delete('items', where: 'id = ?', whereArgs: [r['id']]);
      }
      debugPrint('[vault] purged ${rows.length} item(s) deleted >30 days ago');
    } catch (e) {
      debugPrint('[vault] purge failed: $e');
    }
  }

  /// Quick self-test that the file really is encrypted: the first 16 bytes of
  /// a plain SQLite file are "SQLite format 3\0"; an encrypted one is random.
  Future<bool> isEncryptedOnDisk() async {
    final path = _path;
    if (path == null) return false;
    final raf = await File(path).open();
    try {
      final head = await raf.read(16);
      return String.fromCharCodes(head) != 'SQLite format 3\u0000';
    } finally {
      await raf.close();
    }
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
