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
  final int fps;
  final String networkType;
  final String healthStatus;

  TelemetryState({
    required this.elapsedTime,
    required this.currentBitrateKbps,
    required this.batteryLevel,
    required this.streamStatus,
    this.fps = 30,
    this.networkType = "Wi-Fi",
    this.healthStatus = "EXCELLENT",
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

  // Features: Adaptive Bitrate & Controls
  bool _isAdaptiveBitrateEnabled = true;
  int _currentAdaptiveBitrateKbps = 6000;
  bool _isFlashlightOn = false;
  String _networkType = "Wi-Fi";
  int _consecutiveLowBitrateTicks = 0;
  int _consecutiveGoodBitrateTicks = 0;

  // Focus & Exposure Controls
  Offset? _focusPoint;
  bool _showFocusRing = false;
  Timer? _focusRingTimer;
  bool _showExposureSlider = false;
  int _minExposure = -4;
  int _maxExposure = 4;
  int _currentExposure = 0;
  bool _isPipEnabled = false;
  String _selectedAudioInputDeviceKey = "0_Built-in Microphone";

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
    // Reinforce full-screen immersive after orientation switch
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    _telemetryNotifier = ValueNotifier<TelemetryState>(TelemetryState(
      elapsedTime: Duration.zero,
      currentBitrateKbps: 0,
      batteryLevel: 100,
      streamStatus: "Initializing camera...",
    ));

    _channel.setMethodCallHandler(_handleNativeMethodCall);
    _requestPermissionsAndInit();
    _startBatteryMonitoring();
    _fetchNetworkType();
    _startVuMeterTimer();
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
        _fetchExposureRange();
      }
    } on PlatformException catch (e) {
      _updateStatusText("Fault: ${e.message}");
    }
  }

  Future<void> _fetchExposureRange() async {
    try {
      final Map<dynamic, dynamic>? range = await _channel.invokeMethod<Map<dynamic, dynamic>>('getExposureRange');
      if (range != null && mounted) {
        setState(() {
          _minExposure = (range['min'] as num?)?.toInt() ?? -4;
          _maxExposure = (range['max'] as num?)?.toInt() ?? 4;
          _currentExposure = (range['current'] as num?)?.toInt() ?? 0;
        });
      }
    } catch (_) {}
  }

  Future<void> _triggerTapToFocus(double x, double y) async {
    try {
      await _channel.invokeMethod('tapToFocus', {'x': x, 'y': y});
    } catch (_) {}
  }

  Future<void> _setExposure(int value) async {
    try {
      await _channel.invokeMethod('setExposure', {'exposure': value});
      setState(() {
        _currentExposure = value;
      });
    } catch (_) {}
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

        _processAdaptiveBitrate(bitrateKbps);

        final target = _bitrateKbps;
        final String health;
        if (bitrateKbps >= target * 0.7) {
          health = "EXCELLENT";
        } else if (bitrateKbps >= target * 0.4) {
          health = "WEAK";
        } else {
          health = "POOR";
        }

        _telemetryNotifier.value = TelemetryState(
          elapsedTime: _telemetryNotifier.value.elapsedTime,
          currentBitrateKbps: bitrateKbps,
          batteryLevel: _telemetryNotifier.value.batteryLevel,
          streamStatus: _telemetryNotifier.value.streamStatus,
          fps: _fps,
          networkType: _networkType,
          healthStatus: health,
        );
        break;
    }
  }

  Future<void> _fetchNetworkType() async {
    try {
      final String? type = await _channel.invokeMethod<String>('getNetworkType');
      if (type != null && mounted) {
        setState(() {
          _networkType = type;
        });
      }
    } catch (_) {}
  }

  Future<void> _toggleFlashlight() async {
    try {
      final bool? isOn = await _channel.invokeMethod<bool>('toggleFlashlight');
      if (isOn != null && mounted) {
        setState(() {
          _isFlashlightOn = isOn;
        });
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Flashlight: $e")),
      );
    }
  }

  void _processAdaptiveBitrate(int currentKbps) {
    if (!_isAdaptiveBitrateEnabled || !_isStreamingNotifier.value) return;

    final targetKbps = _bitrateKbps;
    final lowThreshold = (targetKbps * 0.55).round();

    if (currentKbps < lowThreshold && currentKbps > 50) {
      _consecutiveLowBitrateTicks++;
      _consecutiveGoodBitrateTicks = 0;

      if (_consecutiveLowBitrateTicks >= 3) {
        _consecutiveLowBitrateTicks = 0;
        final newBitrate = (_currentAdaptiveBitrateKbps * 0.75).round().clamp(400, targetKbps);
        if (newBitrate != _currentAdaptiveBitrateKbps) {
          _currentAdaptiveBitrateKbps = newBitrate;
          _channel.invokeMethod('setVideoBitrate', {'bitrate': newBitrate * 1000});
        }
      }
    } else if (currentKbps >= (targetKbps * 0.85).round()) {
      _consecutiveGoodBitrateTicks++;
      _consecutiveLowBitrateTicks = 0;

      if (_consecutiveGoodBitrateTicks >= 8) {
        _consecutiveGoodBitrateTicks = 0;
        if (_currentAdaptiveBitrateKbps < targetKbps) {
          final newBitrate = (_currentAdaptiveBitrateKbps * 1.2).round().clamp(400, targetKbps);
          _currentAdaptiveBitrateKbps = newBitrate;
          _channel.invokeMethod('setVideoBitrate', {'bitrate': newBitrate * 1000});
        }
      }
    }
  }

  double _audioVuLevel = 0.0;
  Timer? _vuTimer;

  void _startVuMeterTimer() {
    _vuTimer?.cancel();
    _vuTimer = Timer.periodic(const Duration(milliseconds: 120), (timer) {
      if (!_isMicMutedNotifier.value && _isNativeInitialized) {
        final double target = (_isStreamingNotifier.value ? 0.35 + ((DateTime.now().millisecondsSinceEpoch ~/ 150) % 5) * 0.12 : 0.15);
        if (mounted) {
          setState(() {
            _audioVuLevel = target.clamp(0.0, 1.0);
          });
        }
      } else {
        if (_audioVuLevel != 0.0 && mounted) {
          setState(() {
            _audioVuLevel = 0.0;
          });
        }
      }
    });
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

    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Camera Source',
      barrierColor: Colors.black.withValues(alpha: 0.5),
      transitionDuration: const Duration(milliseconds: 250),
      pageBuilder: (context, anim1, anim2) {
        final mq = MediaQuery.of(context);
        final panelWidth = mq.size.width > mq.size.height
            ? mq.size.height * 0.80   // landscape: 80% of height
            : mq.size.width * 0.70;    // portrait: 70% of width

        return Align(
          alignment: Alignment.centerRight,
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: panelWidth,
              height: double.infinity,
              decoration: const BoxDecoration(
                color: Color(0xFF0F172A),
                borderRadius: BorderRadius.horizontal(left: Radius.circular(20)),
                border: Border(left: BorderSide(color: Color(0xFF1E293B), width: 1.2)),
                boxShadow: [BoxShadow(color: Colors.black54, blurRadius: 20)],
              ),
              child: SafeArea(
                child: DefaultTabController(
                  length: 2,
                  child: Padding(
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
                            IconButton(
                              onPressed: () => Navigator.of(context).pop(),
                              icon: const Icon(Icons.close_rounded, color: Color(0xFF94A3B8), size: 18),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),

                        // 2. Minimal Tab Selector
                        Container(
                          height: 38,
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            color: const Color(0xFF050811),
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
                            labelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 11),
                            unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w500, fontSize: 11),
                            tabs: const [
                              Tab(
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.smartphone_rounded, size: 14),
                                    SizedBox(width: 4),
                                    Expanded(child: Text("Internal", overflow: TextOverflow.ellipsis, textAlign: TextAlign.center)),
                                  ],
                                ),
                              ),
                              Tab(
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.usb_rounded, size: 14),
                                    SizedBox(width: 4),
                                    Expanded(child: Text("USB OTG", overflow: TextOverflow.ellipsis, textAlign: TextAlign.center)),
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
              ),
            ),
          ),
        );
      },
      transitionBuilder: (context, anim1, anim2, child) {
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(1.0, 0.0),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: anim1, curve: Curves.easeOutCubic)),
          child: child,
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

                  // Metadata Badges Row (using Wrap to prevent any pixel overflow)
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 4,
                    runSpacing: 2,
                    children: [
                      Text(
                        resLabel,
                        style: const TextStyle(color: Color(0xFF64748B), fontSize: 10, fontWeight: FontWeight.w500),
                      ),
                      if (fov != null && fov != '0') ...[
                        const Text("•", style: TextStyle(color: Color(0xFF334155), fontSize: 9)),
                        Text(
                          "$fov° FOV",
                          style: const TextStyle(color: Color(0xFF10B981), fontSize: 10, fontWeight: FontWeight.w500),
                        ),
                      ],
                      if (focalLength != null && focalLength != '0.0') ...[
                        const Text("•", style: TextStyle(color: Color(0xFF334155), fontSize: 9)),
                        Text(
                          "${focalLength}mm",
                          style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 10, fontWeight: FontWeight.w500),
                        ),
                      ],
                      if (hasAF) ...[
                        const Text("•", style: TextStyle(color: Color(0xFF334155), fontSize: 9)),
                        const Text(
                          "AF",
                          style: TextStyle(color: Color(0xFF94A3B8), fontSize: 10, fontWeight: FontWeight.w500),
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
    final previousCameraId = _selectedCameraId;
    try {
      await _channel.invokeMethod('switchCamera', {'cameraId': cameraId});
      if (!mounted) return;
      setState(() {
        _selectedCameraId = cameraId;
      });
      _fetchZoomRange();
    } on PlatformException catch (e) {
      if (!mounted) return;
      // Revert to the previous working camera
      setState(() {
        _selectedCameraId = previousCameraId;
      });

      String message;
      if (e.code == 'USB_PERMISSION_REQUIRED') {
        message = "USB permission required. Please grant permission and try again.";
      } else if (e.code == 'CAMERA_SWITCH_FAILED') {
        message = "Failed to activate external camera. Reverted to main camera.";
      } else {
        message = "Camera switch failed: ${e.message}";
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: const Color(0xFFEF4444),
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _selectedCameraId = previousCameraId;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Failed to switch camera: $e"),
          backgroundColor: const Color(0xFFEF4444),
        ),
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
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _uptimeTimer?.cancel();
    _batteryTimer?.cancel();
    _connectionTimeoutTimer?.cancel();
    _zoomThrottleTimer?.cancel();
    _vuTimer?.cancel();
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
      body: SafeArea(
        child: Container(
          color: const Color(0xFF030712),
          child: Center(
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: Stack(
                  children: [
                    // ── 1. NATIVE CAMERA VIEWPORT ──
                    Positioned.fill(
                      child: _isNativeInitialized
                          ? GestureDetector(
                              onTapDown: (details) {
                                final x = details.localPosition.dx;
                                final y = details.localPosition.dy;
                                _triggerTapToFocus(x, y);

                                _focusRingTimer?.cancel();
                                setState(() {
                                  _focusPoint = details.localPosition;
                                  _showFocusRing = true;
                                });
                                _focusRingTimer = Timer(const Duration(milliseconds: 1200), () {
                                  if (mounted) {
                                    setState(() {
                                      _showFocusRing = false;
                                    });
                                  }
                                });
                              },
                              child: const NativeCameraPreview(),
                            )
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

                    // Focus Ring Overlay
                    if (_showFocusRing && _focusPoint != null)
                      Positioned(
                        left: _focusPoint!.dx - 24,
                        top: _focusPoint!.dy - 24,
                        child: IgnorePointer(
                          child: Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              border: Border.all(color: const Color(0xFF10B981), width: 1.5),
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ),
                      ),

                    // ── 2. SUBTLE TOP/BOTTOM VIGNETTE ──
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Container(
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Color(0x99000000),
                                Colors.transparent,
                                Colors.transparent,
                                Color(0x66000000),
                              ],
                              stops: [0.0, 0.18, 0.82, 1.0],
                            ),
                          ),
                        ),
                      ),
                    ),

                    // ── 3. UI OVERLAYS (all inside 16:9) ──
                    Positioned.fill(
                      child: Stack(
                        children: [

                          // ━━━ TOP STATUS BAR ━━━
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
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: const Color(0xCC0F172A),
                                      borderRadius: BorderRadius.circular(16),
                                      border: Border.all(
                                        color: isLive
                                            ? const Color(0xFFEF4444).withValues(alpha: 0.3)
                                            : const Color(0xFF1E293B),
                                        width: 0.6,
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        // Live / Standby Tag
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: isLive
                                                ? const Color(0xFFEF4444)
                                                : isConnecting
                                                    ? const Color(0xFFF59E0B)
                                                    : const Color(0xFF334155),
                                            borderRadius: BorderRadius.circular(10),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                isLive ? Icons.sensors_rounded : Icons.circle,
                                                size: 8,
                                                color: Colors.white,
                                              ),
                                              const SizedBox(width: 4),
                                              Text(
                                                _formatDuration(telemetry.elapsedTime),
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 9,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 8),

                                        // Health Dot
                                        Icon(
                                          Icons.circle,
                                          size: 7,
                                          color: telemetry.healthStatus == "EXCELLENT"
                                              ? const Color(0xFF10B981)
                                              : telemetry.healthStatus == "WEAK"
                                                  ? const Color(0xFFF59E0B)
                                                  : const Color(0xFFEF4444),
                                        ),
                                        const SizedBox(width: 4),

                                        // Resolution Tag
                                        Text(
                                          "${_height}p$_fps",
                                          style: const TextStyle(
                                            color: Color(0xFF94A3B8),
                                            fontSize: 9,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),

                                        // Divider
                                        Container(
                                          width: 1, height: 10,
                                          margin: const EdgeInsets.symmetric(horizontal: 5),
                                          color: const Color(0xFF334155),
                                        ),

                                        // Bitrate
                                        const Icon(Icons.signal_cellular_alt_rounded, size: 10, color: Color(0xFF38BDF8)),
                                        const SizedBox(width: 3),
                                        Text(
                                          "${telemetry.currentBitrateKbps}K",
                                          style: const TextStyle(
                                            color: Color(0xFF94A3B8),
                                            fontSize: 9,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),

                                        // Network Type Badge
                                        Container(
                                          width: 1, height: 10,
                                          margin: const EdgeInsets.symmetric(horizontal: 5),
                                          color: const Color(0xFF334155),
                                        ),
                                        Icon(
                                          telemetry.networkType == "Wi-Fi" ? Icons.wifi_rounded : Icons.cell_tower_rounded,
                                          size: 10,
                                          color: const Color(0xFF818CF8),
                                        ),
                                        const SizedBox(width: 2),
                                        Text(
                                          telemetry.networkType,
                                          style: const TextStyle(
                                            color: Color(0xFF818CF8),
                                            fontSize: 8.5,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),

                                        // ABR Active Badge
                                        if (_isAdaptiveBitrateEnabled) ...[
                                          Container(
                                            width: 1, height: 10,
                                            margin: const EdgeInsets.symmetric(horizontal: 5),
                                            color: const Color(0xFF334155),
                                          ),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFF10B981).withValues(alpha: 0.2),
                                              borderRadius: BorderRadius.circular(4),
                                            ),
                                            child: const Text(
                                              "ABR",
                                              style: TextStyle(
                                                color: Color(0xFF10B981),
                                                fontSize: 7.5,
                                                fontWeight: FontWeight.w900,
                                              ),
                                            ),
                                          ),
                                        ],

                                        // Divider
                                        Container(
                                          width: 1, height: 10,
                                          margin: const EdgeInsets.symmetric(horizontal: 5),
                                          color: const Color(0xFF334155),
                                        ),

                                        // Battery
                                        Icon(
                                          telemetry.batteryLevel > 20
                                              ? Icons.battery_std_rounded
                                              : Icons.battery_alert_rounded,
                                          size: 10,
                                          color: telemetry.batteryLevel > 20
                                              ? const Color(0xFF10B981)
                                              : const Color(0xFFEF4444),
                                        ),
                                        const SizedBox(width: 2),
                                        Text(
                                          "${telemetry.batteryLevel}%",
                                          style: const TextStyle(
                                            color: Color(0xFF94A3B8),
                                            fontSize: 9,
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

                          // ━━━ FLOATING BACK BUTTON (top-left) ━━━
                          Positioned(
                            top: 6,
                            left: 8,
                            child: _InteractiveButton(
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
                                width: 32,
                                height: 32,
                                decoration: BoxDecoration(
                                  color: const Color(0xB30F172A),
                                  shape: BoxShape.circle,
                                  border: Border.all(color: const Color(0x33FFFFFF), width: 0.6),
                                ),
                                alignment: Alignment.center,
                                child: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 14),
                              ),
                            ),
                          ),

                          // ━━━ UNIFIED SYMMETRIC BOTTOM AUDIO VU BAR (stuck to bottom edge) ━━━
                          Positioned(
                            bottom: 0,
                            left: 90,
                            right: 90,
                            child: IgnorePointer(
                              child: Builder(
                                builder: (context) {
                                  final vuColor = _audioVuLevel > 0.85
                                      ? const Color(0xFFEF4444)
                                      : _audioVuLevel > 0.6
                                          ? const Color(0xFFF59E0B)
                                          : const Color(0xFF10B981);

                                  return SizedBox(
                                    height: 3,
                                    child: Row(
                                      children: [
                                        // Left wing (expands center -> left)
                                        Expanded(
                                          child: RotatedBox(
                                            quarterTurns: 2,
                                            child: ClipRRect(
                                              borderRadius: const BorderRadius.horizontal(right: Radius.circular(2)),
                                              child: LinearProgressIndicator(
                                                value: _audioVuLevel,
                                                backgroundColor: Colors.white.withValues(alpha: 0.12),
                                                valueColor: AlwaysStoppedAnimation<Color>(vuColor),
                                              ),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 2),
                                        // Right wing (expands center -> right)
                                        Expanded(
                                          child: ClipRRect(
                                            borderRadius: const BorderRadius.horizontal(right: Radius.circular(2)),
                                            child: LinearProgressIndicator(
                                              value: _audioVuLevel,
                                              backgroundColor: Colors.white.withValues(alpha: 0.12),
                                              valueColor: AlwaysStoppedAnimation<Color>(vuColor),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),

                          // ━━━ CAMERA NODE TAG (bottom-left) ━━━
                          Positioned(
                            bottom: 8,
                            left: 8,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: const Color(0xB30F172A),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: const Color(0x33FFFFFF), width: 0.6),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.videocam_rounded, size: 12, color: Color(0xFF10B981)),
                                  const SizedBox(width: 4),
                                  Text(
                                    widget.cameraId.toUpperCase(),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 9,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),

                          // ━━━ RIGHT STUDIO CONTROL PANEL (glass sidebar) ━━━
                          Positioned(
                            right: 4,
                            top: 4,
                            bottom: 4,
                            child: Container(
                              width: 72,
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              decoration: BoxDecoration(
                                color: const Color(0xD90F172A),
                                borderRadius: BorderRadius.circular(28),
                                border: Border.all(color: const Color(0xFF1E293B), width: 0.8),
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                children: [
                                  // 1. Mic
                                  ValueListenableBuilder<bool>(
                                    valueListenable: _isMicMutedNotifier,
                                    builder: (context, isMuted, child) {
                                      return _buildPanelButton(
                                        icon: isMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
                                        label: "Mic",
                                        onTap: _toggleMic,
                                        iconColor: isMuted ? const Color(0xFFEF4444) : null,
                                        isActive: !isMuted,
                                      );
                                    },
                                  ),

                                  // 2. Camera
                                  _buildPanelButton(
                                    icon: Icons.linked_camera_rounded,
                                    label: "Camera",
                                    onTap: _openTabbedCameraModal,
                                  ),

                                  // 3. Exp (Exposure)
                                  _buildPanelButton(
                                    icon: Icons.brightness_6_rounded,
                                    label: "Exp",
                                    onTap: () {
                                      setState(() {
                                        _showExposureSlider = !_showExposureSlider;
                                        if (_showExposureSlider) {
                                          _showZoomSlider = false;
                                        }
                                      });
                                    },
                                    isActive: _showExposureSlider,
                                  ),

                                  // 4. GO LIVE / STOP (Center Button)
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
                                              width: 36,
                                              height: 36,
                                              decoration: BoxDecoration(
                                                color: isStreaming
                                                    ? const Color(0xFFEF4444)
                                                    : const Color(0xFFEF4444).withValues(alpha: 0.85),
                                                shape: BoxShape.circle,
                                                boxShadow: [
                                                  BoxShadow(
                                                    color: const Color(0xFFEF4444).withValues(alpha: 0.4),
                                                    blurRadius: 12,
                                                    spreadRadius: 1,
                                                  ),
                                                ],
                                              ),
                                              alignment: Alignment.center,
                                              child: isConnecting
                                                  ? const SizedBox(
                                                      width: 14, height: 14,
                                                      child: CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                                      ),
                                                    )
                                                  : Text(
                                                      isStreaming ? "STOP" : "LIVE",
                                                      style: const TextStyle(
                                                        color: Colors.white,
                                                        fontSize: 8,
                                                        fontWeight: FontWeight.w900,
                                                        letterSpacing: 0.5,
                                                      ),
                                                    ),
                                            ),
                                          );
                                        },
                                      );
                                    },
                                  ),

                                  // 5. Torch (Flashlight)
                                  _buildPanelButton(
                                    icon: _isFlashlightOn ? Icons.flash_on_rounded : Icons.flash_off_rounded,
                                    label: "Torch",
                                    onTap: _toggleFlashlight,
                                    isActive: _isFlashlightOn,
                                    iconColor: _isFlashlightOn ? const Color(0xFFF59E0B) : null,
                                  ),

                                  // 6. Zoom
                                  _buildPanelButton(
                                    icon: Icons.zoom_in_rounded,
                                    label: "${_zoom.toStringAsFixed(1)}x",
                                    onTap: () {
                                      setState(() {
                                        _showZoomSlider = !_showZoomSlider;
                                        if (_showZoomSlider) {
                                          _showExposureSlider = false;
                                        }
                                      });
                                    },
                                    isActive: _showZoomSlider,
                                  ),

                                  // 7. More / Settings
                                  _buildPanelButton(
                                    icon: Icons.tune_rounded,
                                    label: "More",
                                    onTap: _showSettingsPanel,
                                  ),
                                ],
                              ),
                            ),
                          ),

                          // ━━━ VERTICAL EXPOSURE SLIDER OVERLAY ━━━
                          if (_showExposureSlider)
                            Positioned(
                              left: 24,
                              top: 40,
                              bottom: 40,
                              child: Container(
                                width: 44,
                                padding: const EdgeInsets.symmetric(vertical: 8),
                                decoration: BoxDecoration(
                                  color: const Color(0xE60F172A),
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(color: const Color(0xFF1E293B), width: 0.8),
                                  boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 10)],
                                ),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    const Icon(Icons.brightness_5_rounded, color: Color(0xFF10B981), size: 14),
                                    Expanded(
                                      child: RotatedBox(
                                        quarterTurns: 3,
                                        child: Slider(
                                          value: _currentExposure.toDouble().clamp(_minExposure.toDouble(), _maxExposure.toDouble()),
                                          min: _minExposure.toDouble(),
                                          max: _maxExposure.toDouble(),
                                          divisions: (_maxExposure - _minExposure).clamp(1, 20),
                                          activeColor: const Color(0xFF10B981),
                                          inactiveColor: const Color(0xFF1E293B),
                                          onChanged: (val) => _setExposure(val.round()),
                                        ),
                                      ),
                                    ),
                                    Text(
                                      "${_currentExposure > 0 ? "+" : ""}$_currentExposure",
                                      style: const TextStyle(color: Colors.white, fontSize: 8.5, fontWeight: FontWeight.bold),
                                    ),
                                  ],
                                ),
                              ),
                            ),

                          // ━━━ VERTICAL ZOOM SLIDER OVERLAY ━━━
                          if (_showZoomSlider)
                            Positioned(
                              right: 82,
                              top: 20,
                              bottom: 20,
                              child: Container(
                                width: 48,
                                padding: const EdgeInsets.symmetric(vertical: 10),
                                decoration: BoxDecoration(
                                  color: const Color(0xE60F172A),
                                  borderRadius: BorderRadius.circular(22),
                                  border: Border.all(color: const Color(0xFF1E293B), width: 0.8),
                                  boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 10)],
                                ),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    _buildZoomPresetPill(1.0, "1x"),
                                    _buildZoomPresetPill(2.0, "2x"),
                                    _buildZoomPresetPill(5.0, "5x"),
                                    const SizedBox(height: 4),
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
                                    const SizedBox(height: 4),
                                    Text(
                                      "${_zoom.toStringAsFixed(1)}x",
                                      style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold),
                                    ),
                                  ],
                                ),
                              ),
                            ),

                          // ━━━ PICTURE-IN-PICTURE (PiP) INSET OVERLAY ━━━
                          if (_isPipEnabled)
                            Positioned(
                              right: 82,
                              bottom: 12,
                              child: Container(
                                width: 140,
                                height: 79,
                                decoration: BoxDecoration(
                                  color: const Color(0xFF0F172A),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: const Color(0xFF10B981).withValues(alpha: 0.8),
                                    width: 1.5,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: const Color(0xFF10B981).withValues(alpha: 0.25),
                                      blurRadius: 10,
                                      spreadRadius: 1,
                                    ),
                                  ],
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(10),
                                  child: Stack(
                                    children: [
                                      const AndroidView(
                                        viewType: 'com.custom.srt_stream/pip_view',
                                      ),
                                      Positioned.fill(
                                        child: Material(
                                          color: Colors.transparent,
                                          child: InkWell(
                                            onTap: () {
                                              final nextCam = _selectedCameraId == "0" ? "1" : "0";
                                              _switchCameraTo(nextCam);
                                            },
                                            child: Center(
                                              child: Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                                                decoration: BoxDecoration(
                                                  color: Colors.black.withValues(alpha: 0.55),
                                                  borderRadius: BorderRadius.circular(6),
                                                ),
                                                child: Row(
                                                  mainAxisSize: MainAxisSize.min,
                                                  children: const [
                                                    Icon(Icons.swap_horizontal_circle_rounded, color: Colors.white, size: 10),
                                                    SizedBox(width: 4),
                                                    Text(
                                                      "TAP TO SWAP",
                                                      style: TextStyle(color: Colors.white, fontSize: 7, fontWeight: FontWeight.bold),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Builds a studio control panel button with icon + label (TVU-style).
  Widget _buildPanelButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color? iconColor,
    bool isActive = false,
  }) {
    return _InteractiveButton(
      onPressed: onTap,
      child: SizedBox(
        width: 60,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 20,
              color: iconColor ?? (isActive ? const Color(0xFF10B981) : const Color(0xFFCBD5E1)),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                color: isActive ? const Color(0xFF10B981) : const Color(0xFF94A3B8),
                fontSize: 8,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
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


  void _showSettingsPanel() {
    // Cache the future so it doesn't re-fire on every setModalState rebuild
    final audioInputsFuture = _channel.invokeMethod<List<dynamic>>('getAudioInputs');

    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Settings',
      barrierColor: Colors.black.withValues(alpha: 0.5),
      transitionDuration: const Duration(milliseconds: 250),
      pageBuilder: (context, anim1, anim2) {
        final mq = MediaQuery.of(context);
        final panelWidth = mq.size.width > mq.size.height
            ? mq.size.height * 0.80   // landscape: 80% of height
            : mq.size.width * 0.70;    // portrait: 70% of width

        return Align(
          alignment: Alignment.centerRight,
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: panelWidth,
              height: double.infinity,
              decoration: const BoxDecoration(
                color: Color(0xFF0F172A),
                borderRadius: BorderRadius.horizontal(left: Radius.circular(20)),
                border: Border(left: BorderSide(color: Color(0xFF1E293B), width: 1.2)),
                boxShadow: [BoxShadow(color: Colors.black54, blurRadius: 20)],
              ),
              child: StatefulBuilder(
                builder: (context, setModalState) {
                  final isStreamingLive = _isStreamingNotifier.value;

                  return SafeArea(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(18.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Header
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                "Studio Settings",
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                ),
                              ),
                              IconButton(
                                onPressed: () => Navigator.of(context).pop(),
                                icon: const Icon(Icons.close_rounded, color: Color(0xFF94A3B8), size: 18),
                              ),
                            ],
                          ),
                          const Divider(color: Color(0xFF1E293B), height: 16),

                          // ━━━ AUDIO INPUT SOURCE SELECTION ━━━
                          const Text(
                            "Audio Input Device",
                            style: TextStyle(
                              color: Color(0xFF64748B),
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 8),
                          FutureBuilder<List<dynamic>?>(
                            future: audioInputsFuture,
                            builder: (context, snapshot) {
                              if (snapshot.connectionState == ConnectionState.waiting) {
                                return Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF050811),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(color: const Color(0xFF1E293B), width: 1),
                                  ),
                                  child: Row(
                                    children: const [
                                      SizedBox(
                                        width: 14, height: 14,
                                        child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation(Color(0xFF10B981))),
                                      ),
                                      SizedBox(width: 10),
                                      Text("Loading audio devices...", style: TextStyle(color: Color(0xFF64748B), fontSize: 11.5)),
                                    ],
                                  ),
                                );
                              }

                              final rawDevices = snapshot.data ?? [
                                {'id': '0', 'name': 'Built-in Microphone', 'type': 'Built-in Microphone'}
                              ];

                              // Generate unique key per device item to prevent duplicate value errors in DropdownButtonFormField
                              final List<Map<String, String>> devices = [];
                              final Set<String> seenKeys = {};

                              for (int i = 0; i < rawDevices.length; i++) {
                                final d = rawDevices[i];
                                final map = Map<String, dynamic>.from(d is Map ? d : {});
                                final id = map['id']?.toString() ?? '$i';
                                final name = map['name']?.toString() ?? 'Built-in Microphone';
                                final type = map['type']?.toString() ?? 'Microphone';
                                final key = "${id}_$name";

                                if (!seenKeys.contains(key)) {
                                  seenKeys.add(key);
                                  devices.add({
                                    'id': id,
                                    'name': name,
                                    'type': type,
                                    'key': key,
                                  });
                                }
                              }

                              if (devices.isEmpty) {
                                devices.add({
                                  'id': '0',
                                  'name': 'Built-in Microphone',
                                  'type': 'Built-in Microphone',
                                  'key': '0_Built-in Microphone',
                                });
                              }

                              if (!devices.any((d) => d['key'] == _selectedAudioInputDeviceKey)) {
                                _selectedAudioInputDeviceKey = devices.first['key']!;
                              }

                              return DropdownButtonFormField<String>(
                                initialValue: _selectedAudioInputDeviceKey,
                                dropdownColor: const Color(0xFF0F172A),
                                isExpanded: true,
                                style: const TextStyle(color: Colors.white, fontSize: 11.5),
                                decoration: const InputDecoration(
                                  filled: true,
                                  fillColor: Color(0xFF050811),
                                  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.all(Radius.circular(10)),
                                    borderSide: BorderSide.none,
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.all(Radius.circular(10)),
                                    borderSide: BorderSide(color: Color(0xFF1E293B), width: 1),
                                  ),
                                ),
                                items: devices.map((d) {
                                  final name = d['name']!;
                                  final type = d['type']!;
                                  final key = d['key']!;
                                  final isBt = type.contains('Bluetooth');
                                  final isUsb = type.contains('USB');

                                  return DropdownMenuItem<String>(
                                    value: key,
                                    child: Row(
                                      children: [
                                        Icon(
                                          isBt ? Icons.bluetooth_audio_rounded : isUsb ? Icons.usb_rounded : Icons.mic_rounded,
                                          color: const Color(0xFF10B981),
                                          size: 14,
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            "$name ($type)",
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(color: Colors.white, fontSize: 11.5),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                }).toList(),
                                onChanged: (val) {
                                  if (val != null) {
                                    _selectedAudioInputDeviceKey = val;
                                    final selectedName = devices.firstWhere((d) => d['key'] == val, orElse: () => {'name': val})['name']!;
                                    setModalState(() {});
                                    setState(() {});
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text("Selected input: $selectedName"),
                                        duration: const Duration(seconds: 1),
                                      ),
                                    );
                                  }
                                },
                              );
                            },
                          ),
                          const SizedBox(height: 14),

                          // ━━━ PIP DUAL CAMERA SWITCH TILE ━━━
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: const Color(0xFF050811),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: const Color(0xFF1E293B), width: 1),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.picture_in_picture_alt_rounded, color: Color(0xFF10B981), size: 16),
                                const SizedBox(width: 10),
                                const Expanded(
                                  child: Text(
                                    "Dual Camera (PiP)",
                                    style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                                  ),
                                ),
                                Switch(
                                  value: _isPipEnabled,
                                  activeTrackColor: const Color(0xFF10B981),
                                  onChanged: (val) {
                                    _isPipEnabled = val;
                                    setModalState(() {});
                                    setState(() {});
                                  },
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 14),

                          // ━━━ BITRATE SLIDER ━━━
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                "Target Bitrate",
                                style: TextStyle(color: Color(0xFF64748B), fontSize: 12, fontWeight: FontWeight.w600),
                              ),
                              Text(
                                "${(_bitrateKbps / 1000).toStringAsFixed(1)} Mbps",
                                style: const TextStyle(color: Color(0xFF10B981), fontSize: 12, fontWeight: FontWeight.bold),
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
                                    setModalState(() => _bitrateKbps = val.round());
                                    setState(() => _bitrateKbps = val.round());
                                    _initNativeStream();
                                  },
                          ),
                          const SizedBox(height: 10),

                          // ━━━ ADAPTIVE BITRATE (ABR) SWITCH ━━━
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: const Color(0xFF050811),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: const Color(0xFF1E293B), width: 1),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.auto_graph_rounded, color: Color(0xFF10B981), size: 16),
                                const SizedBox(width: 10),
                                const Expanded(
                                  child: Text(
                                    "Adaptive Bitrate (ABR)",
                                    style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                                  ),
                                ),
                                Switch(
                                  value: _isAdaptiveBitrateEnabled,
                                  activeTrackColor: const Color(0xFF10B981),
                                  onChanged: (val) {
                                    _isAdaptiveBitrateEnabled = val;
                                    setModalState(() {});
                                  },
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 14),

                          // ━━━ RESOLUTION PRESET DROPDOWN ━━━
                          const Text(
                            "Resolution & Frame Rate",
                            style: TextStyle(color: Color(0xFF64748B), fontSize: 12, fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 6),
                          DropdownButtonFormField<String>(
                            initialValue: _resolutionLabel,
                            dropdownColor: const Color(0xFF0F172A),
                            isExpanded: true,
                            style: const TextStyle(color: Colors.white, fontSize: 11.5),
                            decoration: const InputDecoration(
                              filled: true,
                              fillColor: Color(0xFF050811),
                              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.all(Radius.circular(10)),
                                borderSide: BorderSide.none,
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.all(Radius.circular(10)),
                                borderSide: BorderSide(color: Color(0xFF1E293B), width: 1),
                              ),
                            ),
                            items: const [
                              DropdownMenuItem(value: "4K (UHD)", child: Text("4K @ 30fps", overflow: TextOverflow.ellipsis)),
                              DropdownMenuItem(value: "1080p (FHD)", child: Text("1080p @ 30fps - High Motion", overflow: TextOverflow.ellipsis)),
                              DropdownMenuItem(value: "1080p Smooth", child: Text("1080p @ 30fps - Smooth", overflow: TextOverflow.ellipsis)),
                              DropdownMenuItem(value: "720p (HD)", child: Text("720p @ 30fps", overflow: TextOverflow.ellipsis)),
                              DropdownMenuItem(value: "480p (SD)", child: Text("480p @ 30fps", overflow: TextOverflow.ellipsis)),
                              DropdownMenuItem(value: "360p (Low)", child: Text("360p @ 24fps", overflow: TextOverflow.ellipsis)),
                            ],
                            onChanged: isStreamingLive
                                ? null
                                : (val) {
                                    if (val != null) {
                                      setModalState(() {
                                        _resolutionLabel = val;
                                        if (val.startsWith("4K")) {
                                          _width = 3840; _height = 2160; _bitrateKbps = 10000; _fps = 30;
                                        } else if (val == "1080p Smooth") {
                                          _width = 1920; _height = 1080; _bitrateKbps = 4000; _fps = 30;
                                        } else if (val.startsWith("1080p")) {
                                          _width = 1920; _height = 1080; _bitrateKbps = 6000; _fps = 30;
                                        } else if (val.startsWith("720p")) {
                                          _width = 1280; _height = 720; _bitrateKbps = 3000; _fps = 30;
                                        } else if (val.startsWith("480p")) {
                                          _width = 854; _height = 480; _bitrateKbps = 1500; _fps = 30;
                                        } else {
                                          _width = 640; _height = 360; _bitrateKbps = 800; _fps = 24;
                                        }
                                      });
                                      setState(() {});
                                      _initNativeStream();
                                    }
                                  },
                          ),
                          const SizedBox(height: 14),

                          // ━━━ FUTURE EXPANSION CONTAINER ━━━
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: const Color(0xFF050811),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: const Color(0xFF1E293B), width: 1),
                            ),
                            child: Row(
                              children: const [
                                Icon(Icons.add_circle_outline_rounded, color: Color(0xFF64748B), size: 16),
                                SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    "Future Studio Features & Plugins",
                                    style: TextStyle(color: Color(0xFF64748B), fontSize: 10.5, fontWeight: FontWeight.w500),
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
            ),
          ),
        );
      },
      transitionBuilder: (context, anim1, anim2, child) {
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(1.0, 0.0),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: anim1, curve: Curves.easeOutCubic)),
          child: child,
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
