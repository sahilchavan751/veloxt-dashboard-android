import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:permission_handler/permission_handler.dart';

class TelemetryState {
  final Duration elapsedTime;
  final int currentBitrateKbps;
  final int batteryLevel;
  final String streamStatus;

  TelemetryState({
    required this.elapsedTime,
    required this.currentBitrateKbps,
    required this.batteryLevel,
    required this.streamStatus,
  });
}

class BroadcastView extends StatefulWidget {
  final String cameraId;
  final String serverIp;
  final int srtPort;
  final String streamType; // "rtmp" or "srt"
  final String ipVersion;  // "ipv4" or "ipv6"

  const BroadcastView({
    super.key,
    required this.cameraId,
    required this.serverIp,
    required this.srtPort,
    this.streamType = "rtmp",
    this.ipVersion = "ipv4",
  });

  @override
  State<BroadcastView> createState() => _BroadcastViewState();
}

class _BroadcastViewState extends State<BroadcastView> {
  static const MethodChannel _channel = MethodChannel('com.custom.srt_stream/control');
  final Battery _battery = Battery();

  // Color constants optimized for high-readability overlays
  static const Color _overlayDarkTop = Color(0x99050811);
  static const Color _overlayDarkBottom = Color(0xB3050811);
  static const Color _hudBgColor = Color(0xD90F172A); // Slate dark, 85% opacity
  static const Color _hudBorderColor = Color(0xFF1E293B);
  static const Color _buttonBgColor = Color(0xCC0F172A);
  static const Color _buttonBorderColor = Color(0x33FFFFFF);
  
  bool _isNativeInitialized = false;
  
  final ValueNotifier<bool> _isStreamingNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _isConnectingNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _isMicMutedNotifier = ValueNotifier<bool>(false);
  late final ValueNotifier<TelemetryState> _telemetryNotifier;

  int _bitrateKbps = 2000;
  String _resolutionLabel = "720p (HD)";
  int _width = 1280;
  int _height = 720;
  int _fps = 30;
  List<Map<String, String>> _availableCameras = [];
  String? _selectedCameraId;
  
  Timer? _uptimeTimer;
  Timer? _batteryTimer;
  Timer? _connectionTimeoutTimer;
  DateTime? _streamStartTime;
  DateTime _lastBitrateUpdateTime = DateTime.now();
  bool _isStoppingStream = false;
  bool _isReconnecting = false;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    _telemetryNotifier = ValueNotifier<TelemetryState>(TelemetryState(
      elapsedTime: Duration.zero,
      currentBitrateKbps: 0,
      batteryLevel: 100,
      streamStatus: "Initializing camera...",
    ));

    _channel.setMethodCallHandler(_handleNativeMethodCall);
    _requestPermissionsAndInit();
    _startBatteryMonitoring();
  }

  Future<void> _requestPermissionsAndInit() async {
    Map<Permission, PermissionStatus> statuses = await [
      Permission.camera,
      Permission.microphone,
    ].request();

    if (statuses[Permission.camera]!.isGranted && statuses[Permission.microphone]!.isGranted) {
      await _fetchAvailableCameras();
      _initNativeStream();
    } else {
      _updateStatusText("Error: Permissions Denied");
      _showErrorDialog("Camera and Microphone permissions are required to start the stream.");
    }
  }

  Future<void> _fetchAvailableCameras() async {
    try {
      final List<dynamic>? cameras = await _channel.invokeMethod<List<dynamic>>('getAvailableCameras');
      if (cameras != null) {
        _availableCameras = cameras.map((c) {
          final map = Map<String, dynamic>.from(c);
          return {
            'id': map['id']?.toString() ?? '',
            'facing': map['facing']?.toString() ?? '',
            'maxWidth': map['maxWidth']?.toString() ?? '0',
            'maxHeight': map['maxHeight']?.toString() ?? '0',
            'hasAutoFocus': map['hasAutoFocus']?.toString() ?? 'false',
            'sensorOrientation': map['sensorOrientation']?.toString() ?? '0',
            'lensType': map['lensType']?.toString() ?? 'Wide Angle',
            'fovDegrees': map['fovDegrees']?.toString() ?? '0',
            'focalLength': map['focalLength']?.toString() ?? '0',
          };
        }).toList();

        if (_availableCameras.isNotEmpty) {
          // Auto camera lens detector selection strategy:
          // 1. First choice: Back camera with "Wide Angle" lens
          Map<String, String>? autoDetectedCam;
          try {
            autoDetectedCam = _availableCameras.firstWhere(
              (c) => c['facing']?.toLowerCase() == 'back' &&
                  (c['lensType']?.toLowerCase().contains('wide angle') == true ||
                   c['lensType']?.toLowerCase() == 'wide'),
            );
          } catch (_) {}

          // 2. Fallback: Back camera with "Ultra Wide" lens if Wide Angle not found
          if (autoDetectedCam == null) {
            try {
              autoDetectedCam = _availableCameras.firstWhere(
                (c) => c['facing']?.toLowerCase() == 'back' &&
                    c['lensType']?.toLowerCase().contains('ultra wide') == true,
              );
            } catch (_) {}
          }

          // 3. Fallback: Any back camera
          if (autoDetectedCam == null) {
            try {
              autoDetectedCam = _availableCameras.firstWhere(
                (c) => c['facing']?.toLowerCase() == 'back',
              );
            } catch (_) {}
          }

          // 4. Ultimate fallback: First available camera
          autoDetectedCam ??= _availableCameras.first;
          _selectedCameraId = autoDetectedCam['id'];
        }
      }
    } catch (e) {
      debugPrint("Failed to fetch camera list: $e");
    }
  }

  Future<void> _initNativeStream() async {
    try {
      final success = await _channel.invokeMethod<bool>('initStream', {
        'width': _width,
        'height': _height,
        'bitrate': _bitrateKbps * 1000,
        'fps': _fps,
        'streamType': widget.streamType,
        'ipVersion': widget.ipVersion,
      });
      if (success == true) {
        setState(() {
          _isNativeInitialized = true;
        });
        _updateStatusText("Ready (Previewing)");
        _syncMicState();
      }
    } on PlatformException catch (e) {
      _updateStatusText("Fault: ${e.message}");
    }
  }

  Future<void> _syncMicState() async {
    try {
      final isEnabled = await _channel.invokeMethod<bool>('isAudioEnabled');
      if (isEnabled != null) {
        _isMicMutedNotifier.value = !isEnabled;
      }
    } catch (_) {}
  }

  Future<void> _startBatteryMonitoring() async {
    try {
      final level = await _battery.batteryLevel;
      _updateBatteryLevel(level);
    } catch (_) {}
    
    _batteryTimer = Timer.periodic(const Duration(seconds: 60), (timer) async {
      try {
        final level = await _battery.batteryLevel;
        _updateBatteryLevel(level);
        if (_isStreamingNotifier.value) {
          _syncStateToFirestore(isLive: true);
        }
      } catch (_) {}
    });
  }

  void _updateStatusText(String text) {
    _telemetryNotifier.value = TelemetryState(
      elapsedTime: _telemetryNotifier.value.elapsedTime,
      currentBitrateKbps: _telemetryNotifier.value.currentBitrateKbps,
      batteryLevel: _telemetryNotifier.value.batteryLevel,
      streamStatus: text,
    );
  }

  void _updateBatteryLevel(int level) {
    _telemetryNotifier.value = TelemetryState(
      elapsedTime: _telemetryNotifier.value.elapsedTime,
      currentBitrateKbps: _telemetryNotifier.value.currentBitrateKbps,
      batteryLevel: level,
      streamStatus: _telemetryNotifier.value.streamStatus,
    );
  }

  Future<void> _handleNativeMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onConnectionSuccess':
        _onStreamConnected();
        break;
      case 'onConnectionFailed':
        final String reason = call.arguments ?? "unknown";
        _onStreamFailed(reason);
        break;
      case 'onDisconnect':
        _onStreamDisconnected();
        break;
      case 'onNewBitrate':
        _lastBitrateUpdateTime = DateTime.now();
        final int bitrateBps = call.arguments ?? 0;
        final bitrateKbps = (bitrateBps / 1000).round();
        _telemetryNotifier.value = TelemetryState(
          elapsedTime: _telemetryNotifier.value.elapsedTime,
          currentBitrateKbps: bitrateKbps,
          batteryLevel: _telemetryNotifier.value.batteryLevel,
          streamStatus: _telemetryNotifier.value.streamStatus,
        );
        break;
    }
  }

  void _onStreamConnected() {
    _connectionTimeoutTimer?.cancel();
    _streamStartTime = DateTime.now();
    _lastBitrateUpdateTime = DateTime.now();
    _isStreamingNotifier.value = true;
    _isConnectingNotifier.value = false;
    
    _telemetryNotifier.value = TelemetryState(
      elapsedTime: Duration.zero,
      currentBitrateKbps: _telemetryNotifier.value.currentBitrateKbps,
      batteryLevel: _telemetryNotifier.value.batteryLevel,
      streamStatus: "Live",
    );

    _uptimeTimer?.cancel();
    _uptimeTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_streamStartTime != null) {
        final elapsed = DateTime.now().difference(_streamStartTime!);
        _telemetryNotifier.value = TelemetryState(
          elapsedTime: elapsed,
          currentBitrateKbps: _telemetryNotifier.value.currentBitrateKbps,
          batteryLevel: _telemetryNotifier.value.batteryLevel,
          streamStatus: _telemetryNotifier.value.streamStatus,
        );
      }
      
      if (_isStreamingNotifier.value && 
          DateTime.now().difference(_lastBitrateUpdateTime) > const Duration(seconds: 5)) {
        _handleStreamFreeze();
      }
    });

    _syncStateToFirestore(isLive: true);
  }

  Future<void> _handleStreamFreeze() async {
    if (!_isStreamingNotifier.value || _isReconnecting) return;
    _isReconnecting = true;
    
    _updateStatusText("Reconnecting...");
    _isConnectingNotifier.value = true;
    _isStreamingNotifier.value = false;
    _uptimeTimer?.cancel();
    _syncStateToFirestore(isLive: false);
    
    _isStoppingStream = true;
    
    try {
      await _channel.invokeMethod('stopStream');
    } catch (_) {}

    await Future.delayed(const Duration(seconds: 2));
    if (!mounted) {
      _isReconnecting = false;
      return;
    }
    
    _isReconnecting = false;
    _isConnectingNotifier.value = false;
    _toggleStream();
  }

  void _onStreamFailed(String reason) {
    if (_isStoppingStream) return;

    _connectionTimeoutTimer?.cancel();
    _isStreamingNotifier.value = false;
    _isConnectingNotifier.value = false;
    _updateStatusText("Connection Failed");
    _uptimeTimer?.cancel();
    _syncStateToFirestore(isLive: false);
    _showErrorDialog("${widget.streamType.toUpperCase()} connection failed: $reason");
  }

  void _onStreamDisconnected() {
    _connectionTimeoutTimer?.cancel();
    _isStreamingNotifier.value = false;
    _isConnectingNotifier.value = false;
    _updateStatusText("Disconnected");
    _uptimeTimer?.cancel();
    _syncStateToFirestore(isLive: false);
  }

  Future<void> _toggleStream() async {
    if (_isStreamingNotifier.value) {
      _isStoppingStream = true;
      _isConnectingNotifier.value = false;
      _updateStatusText("Stopping...");
      try {
        await _channel.invokeMethod('stopStream');
        _onStreamDisconnected();
      } catch (e) {
        _updateStatusText("Stop Fault");
      }
    } else {
      _isStoppingStream = false;
      _isConnectingNotifier.value = true;
      _updateStatusText("Connecting...");

      _connectionTimeoutTimer?.cancel();
      _connectionTimeoutTimer = Timer(const Duration(seconds: 10), () {
        if (_isConnectingNotifier.value && !_isStreamingNotifier.value) {
          _handleConnectionTimeout();
        }
      });

      final userId = FirebaseAuth.instance.currentUser?.uid ?? "userId";

      // Build the publish URL dynamically based on stream protocol and IP version
      String host = widget.serverIp;
      // Wrap IPv6 literal addresses in square brackets for URL formatting
      if (widget.ipVersion == "ipv6" && host.contains(':') && !host.startsWith('[')) {
        host = '[$host]';
      }

      final String publishUrl;
      if (widget.streamType == "srt") {
        publishUrl = "srt://$host:${widget.srtPort}?streamid=publish:${userId}_${widget.cameraId}";
      } else {
        publishUrl = "rtmp://$host:${widget.srtPort}/${userId}_${widget.cameraId}";
      }

      try {
        await _channel.invokeMethod('startStream', {
          'url': publishUrl,
        });
      } on PlatformException catch (e) {
        _connectionTimeoutTimer?.cancel();
        _isConnectingNotifier.value = false;
        _updateStatusText("Start Fault");
        _showErrorDialog(e.message ?? "Failed to initiate native encoding stream.");
      }
    }
  }

  Future<void> _handleConnectionTimeout() async {
    _isConnectingNotifier.value = false;
    _updateStatusText("Connection Timeout");
    try {
      await _channel.invokeMethod('stopStream');
    } catch (_) {}
    final protocolLabel = widget.streamType.toUpperCase();
    final defaultPort = widget.streamType == "srt" ? "8890" : "1935";
    _showErrorDialog("Connection timed out. Please check that:\n\n"
        "1. The server IP and port are correct and reachable.\n"
        "2. If using an emulator, use 10.0.2.2 instead of 127.0.0.1.\n"
        "3. The server is running and the $protocolLabel port (default $defaultPort) is open.");
  }

  Future<void> _toggleMic() async {
    final isMuted = _isMicMutedNotifier.value;
    try {
      if (isMuted) {
        await _channel.invokeMethod('enableAudio');
        if (!mounted) return;
        _isMicMutedNotifier.value = false;
      } else {
        await _channel.invokeMethod('disableAudio');
        if (!mounted) return;
        _isMicMutedNotifier.value = true;
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Failed to toggle mic: $e")),
      );
    }
  }

  void _switchCamera() {
    if (_availableCameras.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("No camera sensors detected")),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF0F172A),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFF1E293B), width: 1.2),
          ),
          title: const Text(
            "Select Camera Sensor",
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: _availableCameras.map((camera) {
              final isSelected = _selectedCameraId == camera['id'];
              final lensType = camera['lensType'] ?? 'Standard';
              final maxW = int.tryParse(camera['maxWidth'] ?? '0') ?? 0;
              final maxH = int.tryParse(camera['maxHeight'] ?? '0') ?? 0;
              final hasAF = camera['hasAutoFocus'] == 'true';
              final resLabel = maxW >= 3840 ? '4K' : maxW >= 1920 ? '1080p' : maxW >= 1280 ? '720p' : '$maxW x $maxH';

              IconData cameraIcon;
              if (camera['facing']?.toLowerCase() == 'front') {
                cameraIcon = Icons.camera_front_rounded;
              } else if (camera['facing']?.toLowerCase() == 'external') {
                cameraIcon = Icons.usb_rounded;
              } else {
                cameraIcon = Icons.camera_rear_rounded;
              }

              return ListTile(
                leading: Icon(
                  cameraIcon,
                  color: isSelected ? const Color(0xFF10B981) : const Color(0xFF64748B),
                ),
                title: Text(
                  "$lensType (${camera['facing']})",
                  style: TextStyle(
                    color: isSelected ? Colors.white : const Color(0xFF94A3B8),
                    fontSize: 14,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
                subtitle: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E293B),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        resLabel,
                        style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 10, fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (camera['fovDegrees'] != null && camera['fovDegrees'] != '0')
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E293B),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          "${camera['fovDegrees']}° FOV",
                          style: const TextStyle(color: Color(0xFF10B981), fontSize: 10, fontWeight: FontWeight.w600),
                        ),
                      ),
                    if (hasAF)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E293B),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          "AF",
                          style: TextStyle(color: Color(0xFF94A3B8), fontSize: 10, fontWeight: FontWeight.w600),
                        ),
                      ),
                  ],
                ),
                trailing: isSelected ? const Icon(Icons.check_rounded, color: Color(0xFF10B981)) : null,
                onTap: () {
                  Navigator.of(context).pop();
                  _switchCameraTo(camera['id']!);
                },
              );
            }).toList(),
          ),
        );
      },
    );
  }

  Future<void> _switchCameraTo(String cameraId) async {
    try {
      await _channel.invokeMethod('switchCamera', {'cameraId': cameraId});
      if (!mounted) return;
      setState(() {
        _selectedCameraId = cameraId;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Failed to switch camera: $e")),
      );
    }
  }

  Future<void> _syncStateToFirestore({required bool isLive}) async {
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null) return;

    try {
      final docRef = FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .collection('active_cameras')
          .doc(widget.cameraId);

      await docRef.set({
        'isLive': isLive,
        'startedAt': isLive ? FieldValue.serverTimestamp() : null,
        'batteryLevel': _telemetryNotifier.value.batteryLevel,
        'streamType': widget.streamType,
        'ipVersion': widget.ipVersion,
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint("Firestore sync error: $e");
    }
  }

  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF0F172A),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFF1E293B), width: 1.2),
        ),
        title: const Text(
          "Transmission Error",
          style: TextStyle(color: Color(0xFFEF4444), fontWeight: FontWeight.bold, fontSize: 16),
        ),
        content: Text(
          message,
          style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text(
              "Dismiss",
              style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF10B981)),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDuration(Duration d) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final hours = twoDigits(d.inHours);
    final minutes = twoDigits(d.inMinutes.remainder(60));
    final seconds = twoDigits(d.inSeconds.remainder(60));
    return "$hours:$minutes:$seconds";
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]);
    _uptimeTimer?.cancel();
    _batteryTimer?.cancel();
    _connectionTimeoutTimer?.cancel();
    if (_isStreamingNotifier.value) {
      _syncStateToFirestore(isLive: false);
    }
    if (_isNativeInitialized) {
      _channel.invokeMethod('closeStream');
    }
    _isStreamingNotifier.dispose();
    _isConnectingNotifier.dispose();
    _isMicMutedNotifier.dispose();
    _telemetryNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 1. Native Camera Viewport
          Positioned.fill(
            child: _isNativeInitialized
                ? const NativeCameraPreview()
                : Container(
                    color: const Color(0xFF050811),
                    child: const Center(
                      child: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF10B981)),
                        ),
                      ),
                    ),
                  ),
          ),

          // 2. Translucent Edge Shading for Maximum Readability
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      _overlayDarkTop,
                      Colors.transparent,
                      Colors.transparent,
                      _overlayDarkBottom,
                    ],
                    stops: [0.0, 0.25, 0.7, 1.0],
                  ),
                ),
              ),
            ),
          ),

          // 3. Top Header Viewport HUD
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.only(top: 48.0, left: 20.0, right: 20.0, bottom: 16.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Back Button with Tactile Feedback
                  _InteractiveButton(
                    onPressed: () async {
                      if (_isStreamingNotifier.value) {
                        await _toggleStream();
                        if (!context.mounted) return;
                        Navigator.of(context).pop();
                      } else {
                        Navigator.of(context).pop();
                      }
                    },
                    child: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: _buttonBgColor,
                        shape: BoxShape.circle,
                        border: Border.all(color: _buttonBorderColor, width: 0.8),
                      ),
                      alignment: Alignment.center,
                      child: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 16),
                    ),
                  ),

                  // Compact Camera Node Badge
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: _buttonBgColor,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: _buttonBorderColor, width: 0.8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.videocam_rounded, size: 14, color: Color(0xFF10B981)),
                        const SizedBox(width: 6),
                        Text(
                          widget.cameraId.toUpperCase(),
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 11.5,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Standby / Live Indicator Badge
                  ValueListenableBuilder<bool>(
                    valueListenable: _isStreamingNotifier,
                    builder: (context, isLive, child) {
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: isLive ? const Color(0xFFEF4444).withValues(alpha: 0.2) : _buttonBgColor,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: isLive ? const Color(0xFFEF4444).withValues(alpha: 0.4) : _buttonBorderColor,
                            width: 0.8,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                color: isLive ? const Color(0xFFEF4444) : const Color(0xFF64748B),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              isLive ? "LIVE" : "STANDBY",
                              style: TextStyle(
                                color: isLive ? const Color(0xFFEF4444) : const Color(0xFF64748B),
                                fontWeight: FontWeight.w800,
                                fontSize: 10,
                                letterSpacing: 0.8,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),

          // 4. Integrated Sleek Viewfinder Telemetry & Controls Panel
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 24.0),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Viewfinder-Style Integrated HUD Panel (Horizontal Strip)
                    ValueListenableBuilder<TelemetryState>(
                      valueListenable: _telemetryNotifier,
                      builder: (context, telemetry, child) {
                        final isLive = telemetry.streamStatus == "Live";
                        
                        return Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 14.0),
                          decoration: BoxDecoration(
                            color: _hudBgColor,
                            borderRadius: BorderRadius.circular(14.0),
                            border: Border.all(color: _hudBorderColor, width: 1.2),
                          ),
                          child: IntrinsicHeight(
                            child: Row(
                              children: [
                                // Left Section: Status & Uptime
                                Expanded(
                                  flex: 12,
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        "TRANSMISSION STATE",
                                        style: TextStyle(
                                          color: Color(0xFF64748B),
                                          fontSize: 9,
                                          fontWeight: FontWeight.w700,
                                          letterSpacing: 0.8,
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        telemetry.streamStatus.toUpperCase(),
                                        style: TextStyle(
                                          color: isLive 
                                              ? const Color(0xFF10B981) 
                                              : (telemetry.streamStatus.contains("Connecting") 
                                                  ? const Color(0xFF34D399) 
                                                  : Colors.white),
                                          fontSize: 13,
                                          fontWeight: FontWeight.w800,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                                
                                const VerticalDivider(color: Color(0xFF1E293B), width: 24, thickness: 1.2),
                                
                                // Middle Section: Uptime & Bitrate
                                Expanded(
                                  flex: 11,
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        "UPTIME",
                                        style: TextStyle(
                                          color: Color(0xFF64748B),
                                          fontSize: 9,
                                          fontWeight: FontWeight.w700,
                                          letterSpacing: 0.8,
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        _formatDuration(telemetry.elapsedTime),
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 13,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),

                                const VerticalDivider(color: Color(0xFF1E293B), width: 24, thickness: 1.2),

                                // Right Section: Bitrate / Quality
                                Expanded(
                                  flex: 11,
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        "BITRATE",
                                        style: TextStyle(
                                          color: Color(0xFF64748B),
                                          fontSize: 9,
                                          fontWeight: FontWeight.w700,
                                          letterSpacing: 0.8,
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        "${telemetry.currentBitrateKbps} KBPS",
                                        style: const TextStyle(
                                          color: Color(0xFF10B981),
                                          fontSize: 13,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 20),

                    // Controls Row
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        // Flip Camera Sensor Button
                        _buildRoundOverlayButton(
                          icon: Icons.flip_camera_android_rounded,
                          onTap: _switchCamera,
                        ),

                        // Microphone Toggle Button
                        ValueListenableBuilder<bool>(
                          valueListenable: _isMicMutedNotifier,
                          builder: (context, isMuted, child) {
                            return _buildRoundOverlayButton(
                              icon: isMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
                              iconColor: isMuted ? const Color(0xFFEF4444) : const Color(0xFF10B981),
                              onTap: _toggleMic,
                            );
                          },
                        ),

                        // Premium Go Live Action Button
                        ValueListenableBuilder<bool>(
                          valueListenable: _isStreamingNotifier,
                          builder: (context, isStreaming, child) {
                            return ValueListenableBuilder<bool>(
                              valueListenable: _isConnectingNotifier,
                              builder: (context, isConnecting, child) {
                                return _InteractiveButton(
                                  onPressed: isConnecting ? null : _toggleStream,
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 200),
                                    height: 52,
                                    width: 140,
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: isStreaming 
                                          ? const Color(0xFFEF4444) 
                                          : const Color(0xFF10B981),
                                      borderRadius: BorderRadius.circular(26),
                                      boxShadow: [
                                        BoxShadow(
                                          color: (isStreaming ? const Color(0xFFEF4444) : const Color(0xFF10B981))
                                              .withValues(alpha: 0.25),
                                          blurRadius: 15,
                                          spreadRadius: 2,
                                        ),
                                      ],
                                    ),
                                    child: isConnecting
                                        ? const SizedBox(
                                            height: 18,
                                            width: 18,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2.0,
                                              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                            ),
                                          )
                                        : Text(
                                            isStreaming ? "STOP LIVE" : "GO LIVE",
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w700,
                                              letterSpacing: 0.8,
                                              fontSize: 13,
                                              color: Colors.white,
                                            ),
                                          ),
                                  ),
                                );
                              },
                            );
                          },
                        ),

                        // Settings/Configuration Button
                        _buildRoundOverlayButton(
                          icon: Icons.tune_rounded,
                          onTap: _showSettingsPanel,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRoundOverlayButton({
    required IconData icon,
    required VoidCallback onTap,
    Color? iconColor,
  }) {
    return _InteractiveButton(
      onPressed: onTap,
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: _buttonBgColor,
          shape: BoxShape.circle,
          border: Border.all(color: _buttonBorderColor, width: 0.8),
        ),
        alignment: Alignment.center,
        child: Icon(
          icon,
          color: iconColor ?? Colors.white,
          size: 20,
        ),
      ),
    );
  }

  void _showSettingsPanel() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final isStreamingLive = _isStreamingNotifier.value;
            
            return SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 28.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      "Stream Configuration",
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 24),
                    
                    // Bitrate Configuration
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          "Target Bitrate",
                          style: TextStyle(
                            color: Color(0xFF64748B),
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          "$_bitrateKbps kbps",
                          style: const TextStyle(
                            color: Color(0xFF10B981),
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    Slider(
                      value: _bitrateKbps.toDouble(),
                      min: 200,
                      max: 15000,
                      divisions: 148,
                      activeColor: const Color(0xFF10B981),
                      inactiveColor: const Color(0xFF1E293B),
                      onChanged: isStreamingLive
                          ? null
                          : (val) {
                              setModalState(() {
                                _bitrateKbps = val.round();
                              });
                              setState(() {
                                _bitrateKbps = val.round();
                              });
                              _initNativeStream();
                            },
                    ),
                    const SizedBox(height: 20),

                    // Quality (Resolution) Configuration
                    const Text(
                      "Video Resolution",
                      style: TextStyle(
                        color: Color(0xFF64748B),
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      initialValue: _resolutionLabel,
                      dropdownColor: const Color(0xFF0F172A),
                      isExpanded: true,
                      style: const TextStyle(color: Colors.white, fontSize: 13.5),
                      decoration: const InputDecoration(
                        filled: true,
                        fillColor: Color(0xFF050811),
                        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(12)),
                          borderSide: BorderSide.none,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(12)),
                          borderSide: BorderSide(color: Color(0xFF1E293B), width: 1.2),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(12)),
                          borderSide: BorderSide(color: Color(0xFF10B981), width: 1.5),
                        ),
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: "4K (UHD)",
                          child: Text("4K (3840x2160) @ 30fps", overflow: TextOverflow.ellipsis),
                        ),
                        DropdownMenuItem(
                          value: "1080p (FHD)",
                          child: Text("1080p (1920x1080) @ 30fps", overflow: TextOverflow.ellipsis),
                        ),
                        DropdownMenuItem(
                          value: "720p (HD)",
                          child: Text("720p (1280x720) @ 30fps", overflow: TextOverflow.ellipsis),
                        ),
                        DropdownMenuItem(
                          value: "480p (SD)",
                          child: Text("480p (854x480) @ 30fps", overflow: TextOverflow.ellipsis),
                        ),
                        DropdownMenuItem(
                          value: "360p (Low)",
                          child: Text("360p (640x360) @ 24fps", overflow: TextOverflow.ellipsis),
                        ),
                        DropdownMenuItem(
                          value: "240p (Ultra Low)",
                          child: Text("240p (426x240) @ 15fps", overflow: TextOverflow.ellipsis),
                        ),
                      ],
                      onChanged: isStreamingLive
                          ? null
                          : (val) {
                              if (val != null) {
                                setModalState(() {
                                  _resolutionLabel = val;
                                  if (val.startsWith("4K")) {
                                    _width = 3840;
                                    _height = 2160;
                                    _bitrateKbps = 10000;
                                    _fps = 30;
                                  } else if (val.startsWith("1080p")) {
                                    _width = 1920;
                                    _height = 1080;
                                    _bitrateKbps = 4000;
                                    _fps = 30;
                                  } else if (val.startsWith("720p")) {
                                    _width = 1280;
                                    _height = 720;
                                    _bitrateKbps = 2000;
                                    _fps = 30;
                                  } else if (val.startsWith("480p")) {
                                    _width = 854;
                                    _height = 480;
                                    _bitrateKbps = 1000;
                                    _fps = 30;
                                  } else if (val.startsWith("360p")) {
                                    _width = 640;
                                    _height = 360;
                                    _bitrateKbps = 500;
                                    _fps = 24;
                                  } else {
                                    _width = 426;
                                    _height = 240;
                                    _bitrateKbps = 250;
                                    _fps = 15;
                                  }
                                });
                                setState(() {
                                  _resolutionLabel = val;
                                  if (val.startsWith("4K")) {
                                    _width = 3840;
                                    _height = 2160;
                                    _bitrateKbps = 10000;
                                    _fps = 30;
                                  } else if (val.startsWith("1080p")) {
                                    _width = 1920;
                                    _height = 1080;
                                    _bitrateKbps = 4000;
                                    _fps = 30;
                                  } else if (val.startsWith("720p")) {
                                    _width = 1280;
                                    _height = 720;
                                    _bitrateKbps = 2000;
                                    _fps = 30;
                                  } else if (val.startsWith("480p")) {
                                    _width = 854;
                                    _height = 480;
                                    _bitrateKbps = 1000;
                                    _fps = 30;
                                  } else if (val.startsWith("360p")) {
                                    _width = 640;
                                    _height = 360;
                                    _bitrateKbps = 500;
                                    _fps = 24;
                                  } else {
                                    _width = 426;
                                    _height = 240;
                                    _bitrateKbps = 250;
                                    _fps = 15;
                                  }
                                });
                                _initNativeStream();
                              }
                            },
                    ),
                    if (isStreamingLive) ...[
                      const SizedBox(height: 16),
                      const Text(
                        "* Resolution & bitrate are locked while live",
                        style: TextStyle(
                          color: Color(0xFFEF4444),
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class NativeCameraPreview extends StatelessWidget {
  const NativeCameraPreview({super.key});

  @override
  Widget build(BuildContext context) {
    return const RepaintBoundary(
      child: AndroidView(
        viewType: 'com.custom.srt_stream/video_view',
        creationParams: <String, dynamic>{},
        creationParamsCodec: StandardMessageCodec(),
      ),
    );
  }
}

class _InteractiveButton extends StatefulWidget {
  final VoidCallback? onPressed;
  final Widget child;

  const _InteractiveButton({required this.onPressed, required this.child});

  @override
  State<_InteractiveButton> createState() => _InteractiveButtonState();
}

class _InteractiveButtonState extends State<_InteractiveButton> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) {
        if (widget.onPressed != null) {
          setState(() => _scale = 0.97);
        }
      },
      onTapUp: (_) {
        if (widget.onPressed != null) {
          setState(() => _scale = 1.0);
          widget.onPressed!();
        }
      },
      onTapCancel: () {
        if (widget.onPressed != null) {
          setState(() => _scale = 1.0);
        }
      },
      child: AnimatedScale(
        scale: _scale,
        duration: const Duration(milliseconds: 80),
        curve: Curves.easeInOut,
        child: widget.child,
      ),
    );
  }
}
