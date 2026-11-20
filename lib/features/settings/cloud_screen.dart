import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/cloud_sync.dart';
import '../../shared/motion.dart';
import '../../shared/theme.dart';
import '../../shared/ui.dart';

/// Settings → Cloud safety: the whole vault copied to the user's own Google
/// Drive, by itself, every day — and brought back on a new phone.
class CloudScreen extends StatefulWidget {
  const CloudScreen({super.key});

  @override
  State<CloudScreen> createState() => _CloudScreenState();
}

class _CloudScreenState extends State<CloudScreen> {
  String _email = '';
  String _clientId = '';
  DateTime? _last;
  String _error = '';
  bool _auto = true;
  bool _wifi = true;
  bool _storeKey = true;
  bool _loaded = false;
  bool _working = false;
  String _status = '';
  final _idCtl = TextEditingController();

  @override
  void initState() {
    super.initState();
    CloudSync.changed.addListener(_load);
    CloudSync.status.addListener(_onStatus);
    _load();
  }

  @override
  void dispose() {
    CloudSync.changed.removeListener(_load);
    CloudSync.status.removeListener(_onStatus);
    _idCtl.dispose();
    super.dispose();
  }

  void _onStatus() {
    if (mounted) setState(() => _status = CloudSync.status.value);
  }

  Future<void> _load() async {
    final email = await CloudSync.email();
    final id = await CloudSync.webClientId();
    final last = await CloudSync.lastSync();
    final err = await CloudSync.lastError();
    final auto = await CloudSync.autoEnabled();
    final wifi = await CloudSync.wifiOnly();
    final sk = await CloudSync.storeKey();
    if (!mounted) return;
    setState(() {
      _email = email;
      _clientId = id;
      if (!_loaded) _idCtl.text = id;
      _last = last;
      _error = err;
      _auto = auto;
      _wifi = wifi;
      _storeKey = sk;
      _loaded = true;
    });
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _saveId() async {
    await CloudSync.setWebClientId(_idCtl.text);
    if (!mounted) return;
    _snack(_idCtl.text.trim().isEmpty ? 'Client ID removed' : 'Client ID saved');
  }

  Future<void> _signIn() async {
    if (_working) return;
    setState(() => _working = true);
    try {
      final e = await CloudSync.signIn();
      if (mounted) _snack('Signed in as $e');
    } catch (e) {
      if (mounted) _snack('Sign-in failed: $e');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _sync() async {
    if (_working) return;
    setState(() => _working = true);
    try {
      final r = await CloudSync.syncNow();
      if (mounted) _snack(r.ok ? 'Done — ${r.uploaded} uploaded, ${r.skipped} already there.' : 'Backup failed: ${r.error}');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _restore() async {
    if (_working) return;
    setState(() => _working = true);
    CloudInventory inv;
    try {
      inv = await CloudSync.inventory();
    } catch (e) {
      if (mounted) {
        setState(() => _working = false);
        _snack('$e');
      }
      return;
    }
    if (!mounted) return;
    if (!inv.hasVault) {
      setState(() => _working = false);
      _snack('Nothing in Drive yet (no BYTE Vault folder with a vault file).');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore from Drive?'),
        content: Text(
          'Drive has a vault saved ${inv.lastSaved == null ? '' : 'on ${inv.lastSaved!.day}/${inv.lastSaved!.month} ${TimeOfDay.fromDateTime(inv.lastSaved!).format(ctx)}'} '
          'with ${inv.files} files (${(inv.bytes / (1024 * 1024)).toStringAsFixed(0)} MB).\n\n'
          'Everything on this phone will be REPLACED by that copy. Use this on a new phone, or after a reset.'
          '${inv.hasKey ? '' : '\n\nThe recovery key is not in Drive — you\'ll be asked for it.'}',
        ),
        actions: [
          TextButton(style: inlineButton, onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(style: inlineButton, onPressed: () => Navigator.pop(ctx, true), child: const Text('Restore')),
        ],
      ),
    );
    if (ok != true || !mounted) {
      setState(() => _working = false);
      return;
    }
    String? key;
    if (!inv.hasKey) {
      final ctl = TextEditingController();
      key = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Recovery key'),
          content: TextField(controller: ctl, autofocus: true, decoration: const InputDecoration(hintText: 'The 64-character key from the old phone')),
          actions: [
            TextButton(style: inlineButton, onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(style: inlineButton, onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('Use key')),
          ],
        ),
      );
      Future<void>.delayed(const Duration(seconds: 1), ctl.dispose);
      if (key == null || !mounted) {
        setState(() => _working = false);
        return;
      }
    }
    try {
      final r = await CloudSync.restore(recoveryKey: key?.replaceAll(RegExp(r'[^0-9a-fA-F]'), ''));
      if (mounted) _snack('Restored ${r.items} items and ${r.files} files. Restart BYTE to see everything.');
    } catch (e) {
      if (mounted) _snack('Restore failed: $e');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  String _when(DateTime d) {
    final n = DateTime.now();
    final diff = n.difference(d);
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} h ago';
    return '${diff.inDays} day${diff.inDays == 1 ? '' : 's'} ago';
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final signedIn = _email.isNotEmpty;
    final stale = _last == null || DateTime.now().difference(_last!) > const Duration(days: 2);
    final state = !signedIn
        ? 'Not protected yet'
        : _last == null
            ? 'Signed in — first copy not made yet'
            : (stale ? 'Last copy ${_when(_last!)} — overdue' : 'Safe — copied ${_when(_last!)}');
    final detail = _working && _status.isNotEmpty
        ? _status
        : !signedIn
            ? 'If the phone is lost, stolen or dies, everything in BYTE goes with it. Sign in once and BYTE copies the whole vault to your own Google Drive every day.'
            : (_error.isNotEmpty ? 'Last problem: $_error' : 'Recordings, photos, videos, notes, files and the encrypted vault, in Drive → "BYTE Vault" ($_email)');
    return Scaffold(
      appBar: AppBar(title: const Text('Google Drive copy')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                // ── the state, in words ──
                Padding(
                  padding: const EdgeInsets.fromLTRB(ByteSpace.page, 8, ByteSpace.page, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          IconWell(
                            !signedIn ? Icons.cloud_off_outlined : (stale ? Icons.cloud_outlined : Icons.cloud_done_outlined),
                            tone: !signedIn ? 'plain' : (stale ? 'hey' : 'act'),
                          ),
                          const SizedBox(width: 14),
                          Expanded(child: Text(state, style: tt.titleLarge)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(detail, style: tt.bodySmall),
                      if (_working) ...[
                        const SizedBox(height: 12),
                        ClipRRect(borderRadius: BorderRadius.circular(3), child: const LinearProgressIndicator(minHeight: 6)),
                      ],
                      const SizedBox(height: 16),
                      if (!signedIn)
                        FilledButton.icon(onPressed: _working ? null : _signIn, icon: const Icon(Icons.login_rounded), label: const Text('Sign in with Google'))
                      else ...[
                        FilledButton.icon(onPressed: _working ? null : _sync, icon: const Icon(Icons.cloud_upload_outlined), label: const Text('Back up now')),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            TextButton(style: inlineButton, onPressed: _working ? null : _restore, child: const Text('Restore from Drive')),
                            const Spacer(),
                            TextButton(
                              style: inlineButton.copyWith(foregroundColor: WidgetStatePropertyAll(ByteColors.textDim)),
                              onPressed: _working
                                  ? null
                                  : () async {
                                      await CloudSync.signOut();
                                      if (mounted) _snack('Signed out. Backups stop until you sign in again.');
                                    },
                              child: const Text('Sign out'),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),

                const SectionLabel('How it runs'),
                ByteList(
                  children: [
                    ByteRow(
                      icon: Icons.autorenew_rounded,
                      title: 'Automatic, every day',
                      subtitle: 'Also whenever BYTE opens and the last copy is a day old',
                      trailing: ByteSwitch(value: _auto, onChanged: (v) => CloudSync.setAuto(v)),
                    ),
                    ByteRow(
                      icon: Icons.wifi_rounded,
                      title: 'Wi-Fi only',
                      subtitle: 'Videos and recordings are big; turn off to allow mobile data',
                      trailing: ByteSwitch(value: _wifi, onChanged: (v) => CloudSync.setWifiOnly(v)),
                    ),
                    ByteRow(
                      icon: Icons.key_rounded,
                      title: 'Keep the recovery key in Drive too',
                      subtitle: _storeKey ? 'A new phone restores with just your Google sign-in' : 'You type the 64-character key (Settings → Recovery key) when restoring',
                      trailing: ByteSwitch(value: _storeKey, onChanged: (v) => CloudSync.setStoreKey(v)),
                    ),
                  ],
                ),

                const SectionLabel('One-time setup for the Google sign-in'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: ByteSpace.page),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Google wants every app that touches Drive to be registered. It is free and takes 5 minutes on the laptop:\n'
                        '1. console.cloud.google.com → New project "BYTE".\n'
                        '2. APIs & Services → Library → "Google Drive API" → Enable.\n'
                        '3. OAuth consent screen → External → app name BYTE, your email → Save. Under Test users add your own Gmail.\n'
                        '4. Credentials → Create credentials → OAuth client ID → Android: package com.naveen.byteapp, SHA-1 from the command below → Create.\n'
                        '5. Credentials → Create credentials → OAuth client ID → Web application → Create → copy the Client ID and paste it here.\n'
                        'SHA-1 command (PowerShell): keytool -list -v -keystore "\$env:USERPROFILE\\.android\\debug.keystore" -alias androiddebugkey -storepass android',
                        style: tt.bodySmall,
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _idCtl,
                        decoration: const InputDecoration(labelText: 'Web client ID', hintText: '1234567890-abc…apps.googleusercontent.com'),
                        autocorrect: false,
                      ),
                      if (_clientId.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text('Saved: ${_clientId.length > 24 ? '${_clientId.substring(0, 24)}…' : _clientId}', style: tt.bodySmall),
                        ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          FilledButton.tonal(style: inlineButton, onPressed: _saveId, child: const Text('Save ID')),
                          OutlinedButton.icon(
                            style: inlineButton,
                            onPressed: () => launchUrl(Uri.parse('https://console.cloud.google.com/apis/credentials'), mode: LaunchMode.externalApplication),
                            icon: const Icon(Icons.open_in_new_rounded, size: 16),
                            label: const Text('Open Google Cloud'),
                          ),
                          TextButton.icon(
                            style: inlineButton,
                            onPressed: () {
                              Clipboard.setData(const ClipboardData(text: r'keytool -list -v -keystore "$env:USERPROFILE\.android\debug.keystore" -alias androiddebugkey -storepass android'));
                              _snack('SHA-1 command copied');
                            },
                            icon: const Icon(Icons.copy_rounded, size: 16),
                            label: const Text('Copy SHA-1 command'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                const SectionLabel('Good to know'),
                const ByteList(
                  children: [
                    ByteRow(icon: Icons.storage_rounded, title: '15 GB free from Google', subtitle: 'Recordings are about 2 MB per minute; videos are the big ones', titleWeight: FontWeight.w600),
                    ByteRow(icon: Icons.lock_outline_rounded, title: 'The vault file in Drive is encrypted', subtitle: 'Only the recovery key opens it', titleWeight: FontWeight.w600),
                    ByteRow(icon: Icons.delete_outline_rounded, title: 'The bin keeps the Drive copy', subtitle: 'Deleted for good, a photo or video moves to Drive\'s own Trash', titleWeight: FontWeight.w600),
                    ByteRow(icon: Icons.folder_zip_outlined, title: 'The local ZIP backup still runs daily', subtitle: 'In Downloads/BYTE', titleWeight: FontWeight.w600),
                    ByteRow(icon: Icons.phone_android_rounded, title: 'New phone', subtitle: 'Install BYTE, open this screen, sign in, restore from Drive', titleWeight: FontWeight.w600),
                  ],
                ),
              ],
            ),
    );
  }
}
