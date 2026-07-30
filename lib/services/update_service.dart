import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:flutter/services.dart';

/// GitHub-powered in-app update service for Veloxt.
/// Checks the latest release from GitHub Releases API and prompts
/// the user to download + install the new APK if a newer version exists.
class UpdateService {
  // ─── CONFIGURE THESE TO MATCH YOUR GITHUB REPO ───
  static const String _githubOwner = 'sahilchavan751';
  static const String _githubRepo = 'veloxt-dashboard-android';
  static const String _apiUrl =
      'https://api.github.com/repos/$_githubOwner/$_githubRepo/releases/latest';

  /// Call this on app launch to silently check for updates.
  /// Shows a dialog only if a new version is available.
  static Future<void> checkForUpdate(BuildContext context) async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version; // e.g. "1.0.0"

      final response = await http.get(
        Uri.parse(_apiUrl),
        headers: {'Accept': 'application/vnd.github.v3+json'},
      ).timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) return;

      final Map<String, dynamic> release = jsonDecode(response.body);
      final String tagName = release['tag_name'] ?? ''; // e.g. "v1.0.1"
      final String latestVersion = tagName.replaceFirst('v', '');
      final String releaseName = release['name'] ?? 'New Update';
      final String body = release['body'] ?? '';

      // Find the APK download URL from the release assets
      String? apkUrl;
      final List<dynamic> assets = release['assets'] ?? [];
      for (final asset in assets) {
        final name = asset['name']?.toString() ?? '';
        if (name.endsWith('.apk')) {
          apkUrl = asset['browser_download_url']?.toString();
          break;
        }
      }

      if (!_isNewerVersion(currentVersion, latestVersion)) return;
      if (apkUrl == null) return;
      if (!context.mounted) return;

      _showUpdateDialog(context, latestVersion, releaseName, body, apkUrl);
    } catch (e) {
      debugPrint('Update check failed (non-fatal): $e');
    }
  }

  /// Compares semantic version strings (e.g. "1.0.0" vs "1.0.1").
  /// Returns true if [latest] is strictly newer than [current].
  static bool _isNewerVersion(String current, String latest) {
    try {
      final currentParts = current.split('.').map(int.parse).toList();
      final latestParts = latest.split('.').map(int.parse).toList();

      // Pad to 3 parts
      while (currentParts.length < 3) {
        currentParts.add(0);
      }
      while (latestParts.length < 3) {
        latestParts.add(0);
      }

      for (int i = 0; i < 3; i++) {
        if (latestParts[i] > currentParts[i]) return true;
        if (latestParts[i] < currentParts[i]) return false;
      }
      return false; // equal
    } catch (_) {
      return false;
    }
  }

  /// Shows a modern glassmorphic update dialog.
  static void _showUpdateDialog(
    BuildContext context,
    String version,
    String releaseName,
    String changelog,
    String apkUrl,
  ) {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return Dialog(
          backgroundColor: const Color(0xFF0B1120),
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: Color(0xFF1E293B), width: 1.2),
          ),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Rocket icon
                Container(
                  width: 48,
                  height: 48,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: const Color(0xFF10B981).withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.system_update_alt_rounded,
                    color: Color(0xFF10B981),
                    size: 24,
                  ),
                ),
                const SizedBox(height: 16),

                // Title
                Text(
                  'Update Available (v$version)',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 6),
                Text(
                  releaseName,
                  style: const TextStyle(
                    color: Color(0xFF94A3B8),
                    fontSize: 12,
                  ),
                  textAlign: TextAlign.center,
                ),

                // Changelog (scrollable, max 4 lines)
                if (changelog.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Container(
                    constraints: const BoxConstraints(maxHeight: 100),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: const Color(0xFF1E293B),
                        width: 0.8,
                      ),
                    ),
                    child: SingleChildScrollView(
                      child: Text(
                        changelog,
                        style: const TextStyle(
                          color: Color(0xFF94A3B8),
                          fontSize: 11.5,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 20),

                // Update Now button
                GestureDetector(
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _downloadAndInstall(context, apkUrl, version);
                  },
                  child: Container(
                    height: 44,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: const Color(0xFF10B981),
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF10B981).withValues(alpha: 0.3),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.download_rounded, size: 18, color: Colors.white),
                        SizedBox(width: 8),
                        Text(
                          'Update Now',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),

                // Later button
                GestureDetector(
                  onTap: () => Navigator.of(ctx).pop(),
                  child: Container(
                    height: 40,
                    alignment: Alignment.center,
                    child: const Text(
                      'Later',
                      style: TextStyle(
                        color: Color(0xFF64748B),
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Downloads the APK to a temporary file and triggers Android's
  /// package installer via a platform channel.
  static Future<void> _downloadAndInstall(
    BuildContext context,
    String apkUrl,
    String version,
  ) async {
    // Show a persistent download progress overlay
    final overlayEntry = OverlayEntry(
      builder: (context) => _DownloadProgressOverlay(
        apkUrl: apkUrl,
        version: version,
      ),
    );

    if (context.mounted) {
      Overlay.of(context).insert(overlayEntry);
    }

    try {
      // Download APK to the app's cache directory
      final httpClient = HttpClient();
      final request = await httpClient.getUrl(Uri.parse(apkUrl));
      request.followRedirects = true;
      final response = await request.close();

      final tempDir = Directory.systemTemp;
      final apkFile = File('${tempDir.path}/veloxt_update_v$version.apk');
      final sink = apkFile.openWrite();
      await response.pipe(sink);
      await sink.close();
      httpClient.close();

      overlayEntry.remove();

      // Trigger Android installer via platform channel
      const platform = MethodChannel('com.custom.srt_stream/control');
      await platform.invokeMethod('installApk', {'path': apkFile.path});
    } catch (e) {
      overlayEntry.remove();
      debugPrint('APK download/install failed: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Update failed: $e'),
            backgroundColor: const Color(0xFFEF4444),
          ),
        );
      }
    }
  }
}

/// A floating download progress overlay shown while the APK is downloading.
class _DownloadProgressOverlay extends StatelessWidget {
  final String apkUrl;
  final String version;

  const _DownloadProgressOverlay({
    required this.apkUrl,
    required this.version,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      bottom: 80,
      left: 24,
      right: 24,
      child: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          decoration: BoxDecoration(
            color: const Color(0xFF0F172A).withValues(alpha: 0.95),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF1E293B), width: 1.0),
            boxShadow: const [
              BoxShadow(color: Colors.black45, blurRadius: 16, offset: Offset(0, 4)),
            ],
          ),
          child: Row(
            children: [
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF10B981)),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Downloading Veloxt v$version...',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      'Please wait, installing after download',
                      style: TextStyle(
                        color: Color(0xFF64748B),
                        fontSize: 10.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
