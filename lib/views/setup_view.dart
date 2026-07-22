import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'broadcast_view.dart';

class SetupView extends StatefulWidget {
  const SetupView({super.key});

  @override
  State<SetupView> createState() => _SetupViewState();
}

class _SetupViewState extends State<SetupView> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _newCameraIdController = TextEditingController();
  final TextEditingController _serverIpController = TextEditingController();
  final TextEditingController _srtPortController = TextEditingController(text: "1935");

  List<String> _existingCameras = [];
  bool _isLoadingCameras = true;
  String? _selectedCameraId;
  bool _isCreatingNew = false;

  String _streamType = "rtmp"; // "rtmp" or "srt"
  String _ipVersion = "ipv4"; // "ipv4" or "ipv6"

  @override
  void initState() {
    super.initState();
    _fetchExistingCameras();
  }

  Future<void> _fetchExistingCameras() async {
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null) {
      setState(() => _isLoadingCameras = false);
      return;
    }

    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .collection('active_cameras')
          .get();

      final cameras = snapshot.docs.map((doc) => doc.id).toList();
      cameras.sort();

      setState(() {
        _existingCameras = cameras;
        _isLoadingCameras = false;
        if (cameras.length == 1) {
          _selectedCameraId = cameras.first;
        }
      });
    } catch (e) {
      debugPrint("Failed to fetch cameras: $e");
      setState(() => _isLoadingCameras = false);
    }
  }

  Future<void> _confirmAndDeleteCamera(String camId) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF0F172A),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFF1E293B), width: 1.2),
          ),
          title: const Row(
            children: [
              Icon(Icons.delete_outline_rounded, color: Color(0xFFEF4444), size: 22),
              SizedBox(width: 8),
              Text(
                "Delete Camera ID?",
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          content: Text(
            "Are you sure you want to delete camera '$camId'? This action cannot be undone.",
            style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 14),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text("Cancel", style: TextStyle(color: Color(0xFF64748B))),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFEF4444),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text("Delete", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );

    if (confirm != true) return;

    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null) return;

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .collection('active_cameras')
          .doc(camId)
          .delete();

      setState(() {
        _existingCameras.remove(camId);
        if (_selectedCameraId == camId) {
          if (_existingCameras.isNotEmpty) {
            _selectedCameraId = _existingCameras.first;
          } else {
            _selectedCameraId = null;
            _isCreatingNew = true;
          }
        }
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF10B981),
            content: Text("Camera ID '$camId' deleted successfully"),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFFEF4444),
            content: Text("Failed to delete camera: $e"),
          ),
        );
      }
    }
  }

  String get _resolvedCameraId {
    if (_isCreatingNew) {
      return _newCameraIdController.text.trim().toLowerCase();
    }
    return _selectedCameraId ?? '';
  }

  void _handleProceed() {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    final cameraId = _resolvedCameraId;
    final serverIp = _serverIpController.text.trim();
    final defaultPort = _streamType == "srt" ? 8889 : 1935;
    final srtPort = int.tryParse(_srtPortController.text.trim()) ?? defaultPort;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => BroadcastView(
          cameraId: cameraId,
          serverIp: serverIp,
          srtPort: srtPort,
          streamType: _streamType,
          ipVersion: _ipVersion,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _newCameraIdController.dispose();
    _serverIpController.dispose();
    _srtPortController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final emailDisplay = user?.email ?? "Operator";
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          children: [
            // Minimal Title
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  "Stream Setup",
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    letterSpacing: -0.3,
                  ),
                ),
              ),
            ),
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  physics: const ClampingScrollPhysics(),
                  padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 380),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Minimalist Operator Badge
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0F172A),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: const Color(0xFF1E293B),
                              width: 1.2,
                            ),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 32,
                                height: 32,
                                decoration: BoxDecoration(
                                  color: const Color(0xFF10B981).withValues(alpha: 0.1),
                                  shape: BoxShape.circle,
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  emailDisplay.isNotEmpty ? emailDisplay[0].toUpperCase() : "O",
                                  style: const TextStyle(
                                    color: Color(0xFF10B981),
                                    fontWeight: FontWeight.w700,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      "OPERATOR",
                                      style: TextStyle(
                                        fontSize: 9,
                                        color: Color(0xFF64748B),
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 1.0,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      emailDisplay,
                                      style: const TextStyle(
                                        fontSize: 13,
                                        color: Colors.white,
                                        fontWeight: FontWeight.w600,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                              Container(
                                width: 8,
                                height: 8,
                                decoration: const BoxDecoration(
                                  color: Color(0xFF10B981),
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 32),

                        // Form
                        Form(
                          key: _formKey,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // Camera ID Field
                              _buildCameraIdField(theme),
                              const SizedBox(height: 24),

                              // Stream Protocol Selector (RTMP / SRT)
                              _buildSegmentSelector(
                                label: "STREAM PROTOCOL",
                                value: _streamType,
                                options: const ["rtmp", "srt"],
                                labels: const ["RTMP", "SRT"],
                                onChanged: (value) {
                                  setState(() {
                                    _streamType = value;
                                    // Update port to default for selected protocol
                                    _srtPortController.text = value == "srt" ? "8890" : "1935";
                                  });
                                },
                              ),
                              const SizedBox(height: 24),

                              // IP Version Selector (IPv4 / IPv6)
                              _buildSegmentSelector(
                                label: "NETWORK STACK",
                                value: _ipVersion,
                                options: const ["ipv4", "ipv6"],
                                labels: const ["IPv4", "IPv6"],
                                onChanged: (value) {
                                  setState(() {
                                    _ipVersion = value;
                                  });
                                },
                              ),
                              const SizedBox(height: 24),

                              // MediaMTX Server IP Field
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    "SERVER IP OR HOST",
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF94A3B8),
                                      letterSpacing: 1.2,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  TextFormField(
                                    controller: _serverIpController,
                                    style: const TextStyle(fontSize: 14, color: Colors.white),
                                    decoration: InputDecoration(
                                      hintText: _ipVersion == "ipv6" ? "e.g., 2001:db8::1" : "e.g., 10.0.2.2",
                                      hintStyle: const TextStyle(color: Color(0xFF475569)),
                                      filled: true,
                                      fillColor: const Color(0xFF0F172A),
                                      contentPadding: const EdgeInsets.symmetric(
                                        horizontal: 16,
                                        vertical: 16,
                                      ),
                                      helperText: _ipVersion == "ipv6"
                                          ? "Enter an IPv6 address or hostname"
                                          : "Use 10.0.2.2 for local host from emulator",
                                      helperStyle: const TextStyle(color: Color(0xFF64748B), fontSize: 11),
                                      border: const OutlineInputBorder(
                                        borderRadius: BorderRadius.all(Radius.circular(12)),
                                        borderSide: BorderSide.none,
                                      ),
                                      enabledBorder: const OutlineInputBorder(
                                        borderRadius: BorderRadius.all(Radius.circular(12)),
                                        borderSide: BorderSide(color: Color(0xFF1E293B), width: 1.2),
                                      ),
                                      focusedBorder: const OutlineInputBorder(
                                        borderRadius: BorderRadius.all(Radius.circular(12)),
                                        borderSide: BorderSide(color: Color(0xFF10B981), width: 1.5),
                                      ),
                                      errorBorder: const OutlineInputBorder(
                                        borderRadius: BorderRadius.all(Radius.circular(12)),
                                        borderSide: BorderSide(color: Color(0xFFEF4444), width: 1.2),
                                      ),
                                      focusedErrorBorder: const OutlineInputBorder(
                                        borderRadius: BorderRadius.all(Radius.circular(12)),
                                        borderSide: BorderSide(color: Color(0xFFEF4444), width: 1.5),
                                      ),
                                    ),
                                    validator: (value) {
                                      if (value == null || value.trim().isEmpty) {
                                        return "Server IP is required";
                                      }
                                      return null;
                                    },
                                  ),
                                ],
                              ),
                              const SizedBox(height: 24),

                              // Dynamic Port Field (RTMP or SRT)
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _streamType == "srt" ? "SRT TARGET PORT" : "RTMP TARGET PORT",
                                    style: const TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF94A3B8),
                                      letterSpacing: 1.2,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  TextFormField(
                                    controller: _srtPortController,
                                    keyboardType: TextInputType.number,
                                    style: const TextStyle(fontSize: 14, color: Colors.white),
                                    decoration: InputDecoration(
                                      hintText: _streamType == "srt" ? "8890" : "1935",
                                      hintStyle: const TextStyle(color: Color(0xFF475569)),
                                      filled: true,
                                      fillColor: const Color(0xFF0F172A),
                                      contentPadding: const EdgeInsets.symmetric(
                                        horizontal: 16,
                                        vertical: 16,
                                      ),
                                      helperText: _streamType == "srt"
                                          ? "Default MediaMTX SRT port is 8890"
                                          : "Default MediaMTX RTMP port is 1935",
                                      helperStyle: const TextStyle(color: Color(0xFF64748B), fontSize: 11),
                                      border: const OutlineInputBorder(
                                        borderRadius: BorderRadius.all(Radius.circular(12)),
                                        borderSide: BorderSide.none,
                                      ),
                                      enabledBorder: const OutlineInputBorder(
                                        borderRadius: BorderRadius.all(Radius.circular(12)),
                                        borderSide: BorderSide(color: Color(0xFF1E293B), width: 1.2),
                                      ),
                                      focusedBorder: const OutlineInputBorder(
                                        borderRadius: BorderRadius.all(Radius.circular(12)),
                                        borderSide: BorderSide(color: Color(0xFF10B981), width: 1.5),
                                      ),
                                      errorBorder: const OutlineInputBorder(
                                        borderRadius: BorderRadius.all(Radius.circular(12)),
                                        borderSide: BorderSide(color: Color(0xFFEF4444), width: 1.2),
                                      ),
                                      focusedErrorBorder: const OutlineInputBorder(
                                        borderRadius: BorderRadius.all(Radius.circular(12)),
                                        borderSide: BorderSide(color: Color(0xFFEF4444), width: 1.5),
                                      ),
                                    ),
                                    validator: (value) {
                                      if (value == null || value.trim().isEmpty) {
                                        return "Port is required";
                                      }
                                      final val = int.tryParse(value);
                                      if (val == null || val <= 0 || val > 65535) {
                                        return "Enter a valid port (1 - 65535)";
                                      }
                                      return null;
                                    },
                                  ),
                                ],
                              ),
                              const SizedBox(height: 36),

                              // Premium Proceed Button
                              _InteractiveButton(
                                onPressed: _handleProceed,
                                child: Container(
                                  height: 52,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF10B981),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: const Text(
                                    "Configure Preview & Connect",
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 14.5,
                                      color: Colors.white,
                                      letterSpacing: 0.2,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        // Scroll padding for floating bottom nav bar
                        const SizedBox(height: 80),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCameraIdField(ThemeData theme) {
    if (_isLoadingCameras) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "CAMERA IDENTIFIER",
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: Color(0xFF94A3B8),
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            height: 54,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF1E293B), width: 1.2),
            ),
            child: Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF10B981)),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  "Loading node active cameras...",
                  style: TextStyle(fontSize: 13, color: Colors.grey[500]),
                ),
              ],
            ),
          ),
        ],
      );
    }

    if (_isCreatingNew) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                "NEW CAMERA ID",
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF94A3B8),
                  letterSpacing: 1.2,
                ),
              ),
              if (_existingCameras.isNotEmpty)
                GestureDetector(
                  onTap: () {
                    setState(() {
                      _isCreatingNew = false;
                      _newCameraIdController.clear();
                    });
                  },
                  child: const Text(
                    "Use existing",
                    style: TextStyle(
                      fontSize: 11,
                      color: Color(0xFF10B981),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _newCameraIdController,
            style: const TextStyle(fontSize: 14, color: Colors.white),
            decoration: const InputDecoration(
              hintText: "e.g., cam2",
              hintStyle: TextStyle(color: Color(0xFF475569)),
              filled: true,
              fillColor: Color(0xFF0F172A),
              contentPadding: EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 16,
              ),
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
              errorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(12)),
                borderSide: BorderSide(color: Color(0xFFEF4444), width: 1.2),
              ),
              focusedErrorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(12)),
                borderSide: BorderSide(color: Color(0xFFEF4444), width: 1.5),
              ),
            ),
            validator: (value) {
              if (!_isCreatingNew) return null;
              if (value == null || value.trim().isEmpty) {
                return "Camera ID is required";
              }
              if (RegExp(r'[^a-zA-Z0-9_-]').hasMatch(value)) {
                return "Only alphanumeric, dash, and underscore";
              }
              return null;
            },
          ),
        ],
      );
    }

    if (_existingCameras.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF1E293B), width: 1.2),
            ),
            child: const Row(
              children: [
                Icon(Icons.info_outline_rounded, size: 16, color: Color(0xFF64748B)),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    "No active cameras found. Register a new camera below.",
                    style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8), height: 1.3),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            "CAMERA IDENTIFIER",
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: Color(0xFF94A3B8),
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _newCameraIdController,
            style: const TextStyle(fontSize: 14, color: Colors.white),
            decoration: const InputDecoration(
              hintText: "e.g., cam1",
              hintStyle: TextStyle(color: Color(0xFF475569)),
              filled: true,
              fillColor: Color(0xFF0F172A),
              contentPadding: EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 16,
              ),
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
              errorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(12)),
                borderSide: BorderSide(color: Color(0xFFEF4444), width: 1.2),
              ),
              focusedErrorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(12)),
                borderSide: BorderSide(color: Color(0xFFEF4444), width: 1.5),
              ),
            ),
            validator: (value) {
              if (value == null || value.trim().isEmpty) {
                return "Camera ID is required";
              }
              if (RegExp(r'[^a-zA-Z0-9_-]').hasMatch(value)) {
                return "Only alphanumeric, dash, and underscore";
              }
              return null;
            },
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              "CAMERA IDENTIFIER",
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: Color(0xFF94A3B8),
                letterSpacing: 1.2,
              ),
            ),
            if (_selectedCameraId != null && !_isCreatingNew)
              GestureDetector(
                onTap: () => _confirmAndDeleteCamera(_selectedCameraId!),
                child: const Row(
                  children: [
                    Icon(Icons.delete_outline_rounded, size: 14, color: Color(0xFFEF4444)),
                    SizedBox(width: 4),
                    Text(
                      "Delete CamID",
                      style: TextStyle(
                        fontSize: 11,
                        color: Color(0xFFEF4444),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: _selectedCameraId,
                isExpanded: true,
                icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Color(0xFF64748B)),
                dropdownColor: const Color(0xFF0F172A),
                style: const TextStyle(fontSize: 14, color: Colors.white),
                decoration: const InputDecoration(
                  filled: true,
                  fillColor: Color(0xFF0F172A),
                  contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
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
                  errorBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(12)),
                    borderSide: BorderSide(color: Color(0xFFEF4444), width: 1.2),
                  ),
                  focusedErrorBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(12)),
                    borderSide: BorderSide(color: Color(0xFFEF4444), width: 1.5),
                  ),
                ),
                items: [
                  ..._existingCameras.map((camId) {
                    return DropdownMenuItem<String>(
                      value: camId,
                      child: Text(
                        camId,
                        style: const TextStyle(fontSize: 14, color: Colors.white),
                      ),
                    );
                  }),
                  DropdownMenuItem<String>(
                    enabled: false,
                    value: '__divider__',
                    child: Divider(color: Colors.white.withValues(alpha: 0.08), height: 1),
                  ),
                  const DropdownMenuItem<String>(
                    value: '__new__',
                    child: Row(
                      children: [
                        Icon(Icons.add_circle_outline_rounded, size: 18, color: Color(0xFF10B981)),
                        SizedBox(width: 8),
                        Text(
                          "New Camera ID",
                          style: TextStyle(
                            fontSize: 14,
                            color: Color(0xFF10B981),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                onChanged: (value) {
                  if (value == '__new__') {
                    setState(() {
                      _isCreatingNew = true;
                      _selectedCameraId = null;
                    });
                  } else if (value != '__divider__' && value != null) {
                    setState(() {
                      _selectedCameraId = value;
                    });
                  }
                },
                validator: (value) {
                  if (_isCreatingNew) return null;
                  if (value == null || value.isEmpty || value == '__divider__' || value == '__new__') {
                    return "Select an active camera ID";
                  }
                  return null;
                },
              ),
            ),
            if (_selectedCameraId != null && !_isCreatingNew) ...[
              const SizedBox(width: 8),
              InkWell(
                onTap: () => _confirmAndDeleteCamera(_selectedCameraId!),
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  height: 50,
                  width: 50,
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F172A),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFEF4444).withValues(alpha: 0.4), width: 1.2),
                  ),
                  child: const Icon(Icons.delete_outline_rounded, color: Color(0xFFEF4444), size: 20),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildSegmentSelector({
    required String label,
    required String value,
    required List<String> options,
    required List<String> labels,
    required ValueChanged<String> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            color: Color(0xFF94A3B8),
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          height: 48,
          decoration: BoxDecoration(
            color: const Color(0xFF0F172A),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF1E293B), width: 1.2),
          ),
          padding: const EdgeInsets.all(4),
          child: Row(
            children: List.generate(options.length, (index) {
              final isSelected = value == options[index];
              return Expanded(
                child: GestureDetector(
                  onTap: () => onChanged(options[index]),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeInOut,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: isSelected
                          ? const Color(0xFF10B981).withValues(alpha: 0.15)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      border: isSelected
                          ? Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.4), width: 1.2)
                          : null,
                    ),
                    child: Text(
                      labels[index],
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                        color: isSelected ? const Color(0xFF10B981) : const Color(0xFF64748B),
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ],
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
