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

  // Premium glassmorphic color palette
  static const Color _overlayDarkTop = Color(0xAA050811);
  static const Color _overlayDarkBottom = Color(0xC8050811);
  static const Color _hudBgColor = Color(0xE60F172A); // Slate dark 90%
  static const Color _hudBorderColor = Color(0xFF1E293B);
  static const Color _buttonBgColor = Color(0xD90F172A);
  static const Color _buttonBorderColor = Color(0x33FFFFFF);

  bool _isNativeInitialized = false;

  final ValueNotifier<bool> _isStreamingNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _isConnectingNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _isMicMutedNotifier = ValueNotifier<bool>(false);
  late final ValueNotifier<TelemetryState> _telemetryNotifier;

  int _bitrateKbps = 6000; // 6 Mbps for motion-clear 1080p
  String _resolutionLabel = "1080p (FHD)";
  int _width = 1920;
  int _height = 1080;
  int _fps = 30;

  List<Map<String, String>> _availableCameras = [];
  String? _selectedCameraId;

  // Zoom Control state
  double _zoom = 1.0;
  double _minZoom = 1.0;
  double _maxZoom = 10.0;
  bool _showZoomSlider = false;

  Timer? _uptimeTimer;
  Timer? _batteryTimer;
  Timer? _connectionTimeoutTimer;
  Timer? _zoomThrottleTimer;
  double? _pendingZoomTarget;
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
      await _initNativeStream();
      _fetchZoomRange();
    } else {
      _updateStatusText("Error: Permissions Denied");
      _showErrorDialog("Camera and Microphone permissions are required to start the stream.");
    }
  }

  Future<void> _fetchAvailableCameras() async {
    try {
      final List<dynamic>? cameras = await _channel.invokeMethod<List<dynamic>>('getAvailableCameras');
      if (cameras != null) {
        setState(() {
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
              'isPhysical': map['isPhysical']?.toString() ?? 'false',
            };
          }).toList();
        });

        if (_availableCameras.isNotEmpty && _selectedCameraId == null) {
          Map<String, String>? autoDetectedCam;
          // Choice 1: Back Primary Wide Angle (Main 64MP/Primary)
          try {
            autoDetectedCam = _availableCameras.firstWhere(
              (c) => c['facing']?.toLowerCase() == 'back' &&
                  c['lensType']?.toLowerCase().contains('wide') == true,
            );
          } catch (_) {}

          // Choice 2: Any Back Camera
          autoDetectedCam ??= _availableCameras.firstWhere(
            (c) => c['facing']?.toLowerCase() == 'back',
            orElse: () => _availableCameras.first,
          );

          _selectedCameraId = autoDetectedCam['id'];
        }
      }
    } catch (e) {
      debugPrint("Failed to fetch camera list: $e");
    }
  }

  Future<void> _fetchZoomRange() async {
    try {
      final Map<dynamic, dynamic>? range = await _channel.invokeMethod<Map<dynamic, dynamic>>('getZoomRange');
      if (range != null) {
        setState(() {
          _minZoom = (range['min'] as num?)?.toDouble() ?? 1.0;
          _maxZoom = (range['max'] as num?)?.toDouble() ?? 10.0;
          if (_zoom < _minZoom) _zoom = _minZoom;
          if (_zoom > _maxZoom) _zoom = _maxZoom;
        });
      }
    } catch (_) {}
  }

  Future<void> _setZoom(double value) async {
    final clamped = value.clamp(_minZoom, _maxZoom);
    setState(() => _zoom = clamped);
    _pendingZoomTarget = clamped;

    if (_zoomThrottleTimer?.isActive == true) {
      return;
    }

    _zoomThrottleTimer = Timer(const Duration(milliseconds: 30), () async {
      final target = _pendingZoomTarget;
      if (target != null) {
        try {
          await _channel.invokeMethod('setZoom', {'zoom': target});
        } catch (_) {}
      }
    });
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

      String host = widget.serverIp;
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

  // --- Tabbed Camera Sensor Selection Modal (Built-in Lenses vs USB OTG Webcams) ---
  void _openTabbedCameraModal() {
    _fetchAvailableCameras();

    showDialog(
      context: context,
      builder: (context) {
        final screenWidth = MediaQuery.of(context).size.width;
        final screenHeight = MediaQuery.of(context).size.height;

        return DefaultTabController(
          length: 2,
          child: Dialog(
            backgroundColor: const Color(0xFF0B1120),
            surfaceTintColor: Colors.transparent,
            insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: const BorderSide(color: Color(0xFF1E293B), width: 1.0),
            ),
            child: Container(
              width: screenWidth > 600 ? 520 : screenWidth * 0.85,
              height: screenHeight > 450 ? 360 : screenHeight * 0.88,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 1. Header Bar
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: const Color(0xFF10B981).withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(Icons.videocam_rounded, color: Color(0xFF10B981), size: 18),
                      ),
                      const SizedBox(width: 10),
                      const Text(
                        "Camera Source",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.2,
                        ),
                      ),
                      const Spacer(),
                      Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(20),
                          onTap: () => Navigator.of(context).pop(),
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: const BoxDecoration(
                              color: Color(0xFF1E293B),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.close_rounded, color: Color(0xFF94A3B8), size: 16),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // 2. Minimal Tab Selector (No Emojis, Pure Material Icons)
                  Container(
                    height: 38,
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: const Color(0xFF030712),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFF1E293B), width: 1),
                    ),
                    child: TabBar(
                      indicator: BoxDecoration(
                        color: const Color(0xFF1E293B),
                        borderRadius: BorderRadius.circular(7),
                        border: Border.all(color: const Color(0xFF334155), width: 0.8),
                      ),
                      indicatorSize: TabBarIndicatorSize.tab,
                      labelColor: const Color(0xFF10B981),
                      unselectedLabelColor: const Color(0xFF64748B),
                      dividerColor: Colors.transparent,
                      labelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
                      unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w500, fontSize: 12),
                      tabs: const [
                        Tab(
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.smartphone_rounded, size: 15),
                              SizedBox(width: 6),
                              Text("Internal Lenses"),
                            ],
                          ),
                        ),
                        Tab(
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.usb_rounded, size: 15),
                              SizedBox(width: 6),
                              Text("External USB"),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // 3. Tab Views
                  Expanded(
                    child: TabBarView(
                      children: [
                        _buildInternalLensesList(),
                        _buildExternalWebcamsList(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildInternalLensesList() {
    final internalCams = _availableCameras.where((c) => c['facing']?.toLowerCase() != 'external').toList();

    if (internalCams.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.camera_alt_outlined, color: Color(0xFF475569), size: 28),
            SizedBox(height: 8),
            Text("No camera sensors detected", style: TextStyle(color: Color(0xFF64748B), fontSize: 12)),
          ],
        ),
      );
    }

    return ListView.builder(
      physics: const BouncingScrollPhysics(),
      padding: EdgeInsets.zero,
      itemCount: internalCams.length,
      itemBuilder: (context, index) {
        final camera = internalCams[index];
        return _buildCameraTile(camera);
      },
    );
  }

  Widget _buildExternalWebcamsList() {
    final externalCams = _availableCameras.where((c) => c['facing']?.toLowerCase() == 'external').toList();

    if (externalCams.isEmpty) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B).withValues(alpha: 0.6),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.usb_off_rounded, color: Color(0xFF64748B), size: 20),
              ),
              const SizedBox(height: 8),
              const Text(
                "No USB Webcam Detected",
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
              ),
              const SizedBox(height: 2),
              const Text(
                "Connect a USB camera via OTG adapter to stream.",
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xFF64748B), fontSize: 11),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () => _fetchAvailableCameras(),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF10B981),
                  side: const BorderSide(color: Color(0xFF10B981), width: 1),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                icon: const Icon(Icons.refresh_rounded, size: 13),
                label: const Text("Rescan USB Devices", style: TextStyle(fontWeight: FontWeight.w600, fontSize: 11)),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      physics: const BouncingScrollPhysics(),
      padding: EdgeInsets.zero,
      itemCount: externalCams.length,
      itemBuilder: (context, index) {
        final camera = externalCams[index];
        return _buildCameraTile(camera);
      },
    );
  }

  Widget _buildCameraTile(Map<String, String> camera) {
    final isSelected = _selectedCameraId == camera['id'];
    final lensType = camera['lensType'] ?? 'Standard';
    final facing = camera['facing'] ?? 'Back';
    final maxW = int.tryParse(camera['maxWidth'] ?? '0') ?? 0;
    final maxH = int.tryParse(camera['maxHeight'] ?? '0') ?? 0;
    final hasAF = camera['hasAutoFocus'] == 'true';
    final fov = camera['fovDegrees'];
    final focalLength = camera['focalLength'];
    final isPhys = camera['isPhysical'] == 'true';

    final resLabel = maxW >= 3840 ? '4K' : maxW >= 1920 ? '1080p' : maxW >= 1280 ? '720p' : maxW > 0 ? '${maxW}p' : maxH > 0 ? '${maxH}p' : 'Auto';

    IconData cameraIcon;
    if (facing.toLowerCase() == 'front') {
      cameraIcon = Icons.camera_front_rounded;
    } else if (facing.toLowerCase() == 'external') {
      cameraIcon = Icons.usb_rounded;
    } else if (lensType.contains('Ultra')) {
      cameraIcon = Icons.filter_center_focus_rounded;
    } else if (lensType.contains('Telephoto')) {
      cameraIcon = Icons.center_focus_strong_rounded;
    } else {
      cameraIcon = Icons.camera_rear_rounded;
    }

    return InkWell(
      onTap: () {
        Navigator.of(context).pop();
        _switchCameraTo(camera['id']!);
      },
      borderRadius: BorderRadius.circular(10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF10B981).withValues(alpha: 0.1) : const Color(0xFF030712),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? const Color(0xFF10B981) : const Color(0xFF1E293B),
            width: isSelected ? 1.2 : 0.8,
          ),
        ),
        child: Row(
          children: [
            // Left Icon Squircle
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: isSelected ? const Color(0xFF10B981).withValues(alpha: 0.2) : const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                cameraIcon,
                color: isSelected ? const Color(0xFF10B981) : const Color(0xFF94A3B8),
                size: 17,
              ),
            ),
            const SizedBox(width: 10),

            // Camera Details Column
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          lensType,
                          style: TextStyle(
                            color: isSelected ? Colors.white : const Color(0xFFE2E8F0),
                            fontSize: 13,
                            fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E293B),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(
                          facing.toUpperCase(),
                          style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 8.5, fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (isPhys) ...[
                        const SizedBox(width: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: const Color(0xFF3B82F6).withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(3),
                            border: Border.all(color: const Color(0xFF3B82F6).withValues(alpha: 0.5), width: 0.5),
                          ),
                          child: const Text(
                            "SENSOR",
                            style: TextStyle(color: Color(0xFF60A5FA), fontSize: 8, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),

                  // Metadata Badges Row
                  Row(
                    children: [
                      Text(
                        resLabel,
                        style: const TextStyle(color: Color(0xFF64748B), fontSize: 10.5, fontWeight: FontWeight.w500),
                      ),
                      if (fov != null && fov != '0') ...[
                        const Text("  •  ", style: TextStyle(color: Color(0xFF334155), fontSize: 9)),
                        Text(
                          "$fov° FOV",
                          style: const TextStyle(color: Color(0xFF10B981), fontSize: 10.5, fontWeight: FontWeight.w500),
                        ),
                      ],
                      if (focalLength != null && focalLength != '0.0') ...[
                        const Text("  •  ", style: TextStyle(color: Color(0xFF334155), fontSize: 9)),
                        Text(
                          "${focalLength}mm",
                          style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 10.5, fontWeight: FontWeight.w500),
                        ),
                      ],
                      if (hasAF) ...[
                        const Text("  •  ", style: TextStyle(color: Color(0xFF334155), fontSize: 9)),
                        const Text(
                          "AF",
                          style: TextStyle(color: Color(0xFF94A3B8), fontSize: 10.5, fontWeight: FontWeight.w500),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),

            // Selection Indicator
            if (isSelected)
              const Padding(
                padding: EdgeInsets.only(left: 6),
                child: Icon(Icons.check_circle_rounded, color: Color(0xFF10B981), size: 18),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _switchCameraTo(String cameraId) async {
    try {
      await _channel.invokeMethod('switchCamera', {'cameraId': cameraId});
      if (!mounted) return;
      setState(() {
        _selectedCameraId = cameraId;
      });
      _fetchZoomRange();
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
    _zoomThrottleTimer?.cancel();
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
      backgroundColor: const Color(0xFF030712),
      body: Stack(
        children: [
          // 1. Native Camera Viewport — Centered 16:9 TVU-Style Viewfinder Cutout
          Positioned.fill(
            child: Center(
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
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
              ),
            ),
          ),

          // 2. Edge Vignette Shading
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

          // 3. UI Overlays (wrapped in SafeArea to prevent status bar/notch overlap)
          Positioned.fill(
            child: SafeArea(
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  // TOP COMPACT BROADCAST STATUS CAPSULE
                  Positioned(
                    top: 6,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: ValueListenableBuilder<TelemetryState>(
                        valueListenable: _telemetryNotifier,
                        builder: (context, telemetry, child) {
                          final isLive = telemetry.streamStatus == "Live";
                          final isConnecting = telemetry.streamStatus.contains("Connecting");
                          return Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10.0, vertical: 4.0),
                            decoration: BoxDecoration(
                              color: const Color(0xCC030712),
                              borderRadius: BorderRadius.circular(14.0),
                              border: Border.all(
                                color: isLive ? const Color(0xFF10B981).withValues(alpha: 0.4) : const Color(0xFF1E293B),
                                width: 0.8,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // 1. Status Indicator Dot + Text
                                Container(
                                  width: 6,
                                  height: 6,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: isLive
                                        ? const Color(0xFF10B981)
                                        : isConnecting
                                            ? const Color(0xFFF59E0B)
                                            : const Color(0xFF475569),
                                    boxShadow: isLive
                                        ? [BoxShadow(color: const Color(0xFF10B981).withValues(alpha: 0.6), blurRadius: 4)]
                                        : null,
                                  ),
                                ),
                                const SizedBox(width: 5),
                                Text(
                                  telemetry.streamStatus.toUpperCase(),
                                  style: TextStyle(
                                    color: isLive
                                        ? const Color(0xFF10B981)
                                        : isConnecting
                                            ? const Color(0xFFF59E0B)
                                            : const Color(0xFF94A3B8),
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.3,
                                  ),
                                ),

                                // Divider
                                Container(
                                  width: 1,
                                  height: 10,
                                  margin: const EdgeInsets.symmetric(horizontal: 8),
                                  color: const Color(0xFF334155),
                                ),

                                // 2. Timer Icon + Value
                                const Icon(Icons.timer_rounded, size: 11, color: Color(0xFF38BDF8)),
                                const SizedBox(width: 4),
                                Text(
                                  _formatDuration(telemetry.elapsedTime),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),

                                // Divider
                                Container(
                                  width: 1,
                                  height: 10,
                                  margin: const EdgeInsets.symmetric(horizontal: 8),
                                  color: const Color(0xFF334155),
                                ),

                                // 3. Speed/Bitrate Icon + Value
                                const Icon(Icons.speed_rounded, size: 11, color: Color(0xFFF59E0B)),
                                const SizedBox(width: 4),
                                Text(
                                  "${telemetry.currentBitrateKbps} KBPS",
                                  style: const TextStyle(
                                    color: Color(0xFF10B981),
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),

                                // Divider
                                Container(
                                  width: 1,
                                  height: 10,
                                  margin: const EdgeInsets.symmetric(horizontal: 8),
                                  color: const Color(0xFF334155),
                                ),

                                // 4. Battery Icon + Value
                                Icon(
                                  telemetry.batteryLevel > 20
                                      ? Icons.battery_std_rounded
                                      : Icons.battery_alert_rounded,
                                  size: 11,
                                  color: telemetry.batteryLevel > 20
                                      ? const Color(0xFF10B981)
                                      : const Color(0xFFEF4444),
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  "${telemetry.batteryLevel}%",
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ),

                  // 4. LEFT STUDIO DOCK (Navigation, Live Badge, Camera Node, Zoom Button)
                  Positioned(
                    left: 16,
                    top: 14,
                    bottom: 14,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        // Back Button
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
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: _buttonBgColor,
                              shape: BoxShape.circle,
                              border: Border.all(color: _buttonBorderColor, width: 0.8),
                            ),
                            alignment: Alignment.center,
                            child: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 16),
                          ),
                        ),

                        // Standby / Live Indicator Badge
                        ValueListenableBuilder<bool>(
                          valueListenable: _isStreamingNotifier,
                          builder: (context, isLive, child) {
                            return Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              decoration: BoxDecoration(
                                color: isLive ? const Color(0xFFEF4444).withValues(alpha: 0.2) : _buttonBgColor,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: isLive ? const Color(0xFFEF4444).withValues(alpha: 0.4) : _buttonBorderColor,
                                  width: 0.8,
                                ),
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 8,
                                    height: 8,
                                    decoration: BoxDecoration(
                                      color: isLive ? const Color(0xFFEF4444) : const Color(0xFF64748B),
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    isLive ? "LIVE" : "STBY",
                                    style: TextStyle(
                                      color: isLive ? const Color(0xFFEF4444) : const Color(0xFF64748B),
                                      fontWeight: FontWeight.w800,
                                      fontSize: 9,
                                      letterSpacing: 0.8,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),

                        // Camera Node Badge
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                          decoration: BoxDecoration(
                            color: _buttonBgColor,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: _buttonBorderColor, width: 0.8),
                          ),
                          child: Column(
                            children: [
                              const Icon(Icons.videocam_rounded, size: 14, color: Color(0xFF10B981)),
                              const SizedBox(height: 2),
                              Text(
                                widget.cameraId.toUpperCase(),
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 9.5),
                              ),
                            ],
                          ),
                        ),

                        // Interactive Zoom Button (toggles zoom slider overlay)
                        _InteractiveButton(
                          onPressed: () {
                            setState(() => _showZoomSlider = !_showZoomSlider);
                          },
                          child: Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: _showZoomSlider ? const Color(0xFF10B981) : _buttonBgColor,
                              shape: BoxShape.circle,
                              border: Border.all(color: _buttonBorderColor, width: 0.8),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              "${_zoom.toStringAsFixed(1)}x",
                              style: TextStyle(
                                color: _showZoomSlider ? Colors.white : const Color(0xFF10B981),
                                fontWeight: FontWeight.w800,
                                fontSize: 11,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // 5. VERTICAL ZOOM DRAG SLIDER OVERLAY
                  if (_showZoomSlider)
                    Positioned(
                      left: 70,
                      top: 50,
                      bottom: 50,
                      child: Container(
                        width: 54,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(
                          color: _hudBgColor,
                          borderRadius: BorderRadius.circular(25),
                          border: Border.all(color: _hudBorderColor, width: 1.2),
                          boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 12)],
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            // Quick Zoom Preset Pills
                            _buildZoomPresetPill(1.0, "1x"),
                            _buildZoomPresetPill(2.0, "2x"),
                            _buildZoomPresetPill(5.0, "5x"),
                            const SizedBox(height: 8),

                            // Continuous Vertical Zoom Slider
                            Expanded(
                              child: RotatedBox(
                                quarterTurns: 3,
                                child: Slider(
                                  value: _zoom.clamp(_minZoom, _maxZoom),
                                  min: _minZoom,
                                  max: _maxZoom,
                                  activeColor: const Color(0xFF10B981),
                                  inactiveColor: const Color(0xFF1E293B),
                                  onChanged: (val) => _setZoom(val),
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              "${_zoom.toStringAsFixed(1)}x",
                              style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                    ),

                  // 6. RIGHT STUDIO ACTION DOCK (Camera Picker, Mic Mute, Settings, Go Live)
                  Positioned(
                    right: 16,
                    top: 14,
                    bottom: 14,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        // Camera Sensor Switcher (Opens Tabbed Modal)
                        _buildRoundOverlayButton(
                          icon: Icons.linked_camera_rounded,
                          onTap: _openTabbedCameraModal,
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

                        // Settings Panel Button
                        _buildRoundOverlayButton(
                          icon: Icons.tune_rounded,
                          onTap: _showSettingsPanel,
                        ),

                        // Action Button: GO LIVE / STOP LIVE
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
                                    width: 52,
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: isStreaming ? const Color(0xFFEF4444) : const Color(0xFF10B981),
                                      shape: BoxShape.circle,
                                      boxShadow: [
                                        BoxShadow(
                                          color: (isStreaming ? const Color(0xFFEF4444) : const Color(0xFF10B981))
                                              .withValues(alpha: 0.35),
                                          blurRadius: 15,
                                          spreadRadius: 2,
                                        ),
                                      ],
                                    ),
                                    child: isConnecting
                                        ? const SizedBox(
                                            height: 20,
                                            width: 20,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2.2,
                                              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                            ),
                                          )
                                        : Icon(
                                            isStreaming ? Icons.stop_rounded : Icons.play_arrow_rounded,
                                            color: Colors.white,
                                            size: 28,
                                          ),
                                  ),
                                );
                              },
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildZoomPresetPill(double targetZoom, String label) {
    final isSelected = (_zoom - targetZoom).abs() < 0.2;
    return GestureDetector(
      onTap: () => _setZoom(targetZoom),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF10B981) : const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : const Color(0xFF94A3B8),
            fontSize: 9,
            fontWeight: FontWeight.bold,
          ),
        ),
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
        width: 44,
        height: 44,
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
                padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 24.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          "Stream Encoder Settings",
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.close_rounded, color: Color(0xFF94A3B8), size: 20),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Bitrate Configuration Slider
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          "Target Bitrate (Mbps)",
                          style: TextStyle(
                            color: Color(0xFF64748B),
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          "${(_bitrateKbps / 1000).toStringAsFixed(1)} Mbps ($_bitrateKbps kbps)",
                          style: const TextStyle(
                            color: Color(0xFF10B981),
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    Slider(
                      value: _bitrateKbps.toDouble().clamp(200, 15000),
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
                    const SizedBox(height: 16),

                    // Resolution Preset Dropdown
                    const Text(
                      "Video Resolution & Frame Rate",
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
                          child: Text("4K (3840x2160) @ 30fps - 10 Mbps Preset", overflow: TextOverflow.ellipsis),
                        ),
                        DropdownMenuItem(
                          value: "1080p (FHD)",
                          child: Text("1080p (1920x1080) @ 30fps - 6 Mbps Preset (High Motion)", overflow: TextOverflow.ellipsis),
                        ),
                        DropdownMenuItem(
                          value: "720p (HD)",
                          child: Text("720p (1280x720) @ 30fps - 3 Mbps Preset", overflow: TextOverflow.ellipsis),
                        ),
                        DropdownMenuItem(
                          value: "480p (SD)",
                          child: Text("480p (854x480) @ 30fps - 1.5 Mbps Preset", overflow: TextOverflow.ellipsis),
                        ),
                        DropdownMenuItem(
                          value: "360p (Low)",
                          child: Text("360p (640x360) @ 24fps - 0.8 Mbps Preset", overflow: TextOverflow.ellipsis),
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
                                    _bitrateKbps = 6000;
                                    _fps = 30;
                                  } else if (val.startsWith("720p")) {
                                    _width = 1280;
                                    _height = 720;
                                    _bitrateKbps = 3000;
                                    _fps = 30;
                                  } else if (val.startsWith("480p")) {
                                    _width = 854;
                                    _height = 480;
                                    _bitrateKbps = 1500;
                                    _fps = 30;
                                  } else {
                                    _width = 640;
                                    _height = 360;
                                    _bitrateKbps = 800;
                                    _fps = 24;
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
                                    _bitrateKbps = 6000;
                                    _fps = 30;
                                  } else if (val.startsWith("720p")) {
                                    _width = 1280;
                                    _height = 720;
                                    _bitrateKbps = 3000;
                                    _fps = 30;
                                  } else if (val.startsWith("480p")) {
                                    _width = 854;
                                    _height = 480;
                                    _bitrateKbps = 1500;
                                    _fps = 30;
                                  } else {
                                    _width = 640;
                                    _height = 360;
                                    _bitrateKbps = 800;
                                    _fps = 24;
                                  }
                                });
                                _initNativeStream();
                              }
                            },
                    ),
                    if (isStreamingLive) ...[
                      const SizedBox(height: 14),
                      const Text(
                        "* Resolution and bitrate are locked during active live stream",
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
