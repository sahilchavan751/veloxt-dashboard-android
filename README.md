# Veloxt Dashboard (Android Live Streaming Node)

A professional-grade, zero-budget multi-camera live streaming system. This app transforms any Android smartphone into a high-quality wireless RTMP camera node, allowing you to build a multi-angle broadcast studio without expensive capture cards or dedicated hardware.

## 🚀 Key Features

*   **RTMP Streaming Engine:** Native Android encoding using H.264 Video and AAC Audio for ultra-low latency broadcasting.
*   **Dynamic Resolution & Bitrate:** Stream in crisp 4K (3840x2160) on fast Wi-Fi, or drop all the way to 240p (250kbps) for rock-solid stability over weak mobile data connections.
*   **Background / Lockscreen Streaming:** Powered by Android Foreground Services, the stream stays alive and perfectly synced even if you lock the phone or switch apps.
*   **Hardware Audio Sync:** Utilizes Android's `VOICE_COMMUNICATION` pipeline with hardware Echo Cancellation and Noise Suppression to ensure perfect Audio/Video synchronization.
*   **Real-time Telemetry:** Live HUD showing current bitrate, elapsed uptime, battery percentage, and connection status.
*   **Multi-Sensor Support:** Seamlessly switch between Ultra-Wide, Standard, and Selfie cameras while live.
*   **Firebase Integration:** Authenticates users and syncs real-time camera statuses (Live/Standby) to a centralized Firestore database.

## 🛠️ Tech Stack

*   **Frontend UI:** Flutter (Dart) — Beautiful, glassmorphic HUD design.
*   **Backend / Streaming Core:** Native Android (Kotlin) — Interfacing directly with the Camera2 API and OpenGL for maximum performance.
*   **Encoding Library:** [RootEncoder](https://github.com/pedroSG94/RootEncoder) — Handling the heavy lifting of RTMP muxing and hardware encoding.
*   **Database:** Firebase Authentication & Cloud Firestore.
*   **Receiving Server:** [MediaMTX](https://github.com/bluenviron/mediamtx) (Ultra-fast RTMP server).
*   **Production Mixer:** OBS Studio.

## 📡 Architecture: How It Works

1.  **Capture:** The Android app captures raw camera frames and microphone audio.
2.  **Encode:** The native Kotlin service encodes the feed into H.264/AAC.
3.  **Transmit:** The app pushes the feed via the RTMP protocol over Wi-Fi, Mobile Data, or Native IPv6.
4.  **Receive:** A lightweight MediaMTX server running on a PC receives the incoming streams.
5.  **Mix & Broadcast:** OBS Studio pulls the individual feeds from MediaMTX as Media Sources. The director switches camera angles in OBS and broadcasts the final mixed feed to YouTube/Twitch.

## 📖 Setup Guide & Installation

### 1. Requirements
- Android SDK version 21+ (Android 5.0 Lollipop or newer).
- Flutter SDK (for building the UI).
- Firebase project configuration (`google-services.json` must be placed in `android/app/`).

### 2. The Server (PC)
1. Download and run **MediaMTX** on your PC. It will automatically listen on port `1935`.
2. Find your PC's IP address (e.g., `192.168.1.5` on local Wi-Fi, or your public IPv6 address).

### 3. The Camera Node (Phone App Installation)
1. Clone the repository:
   ```bash
   git clone https://github.com/sahilchavan751/veloxt-dashboard-android.git
   ```
2. Navigate to the project directory:
   ```bash
   cd veloxt-dashboard-android
   ```
3. Install dependencies:
   ```bash
   flutter pub get
   ```
4. Connect your Android device via USB (with USB Debugging enabled) or use an emulator.
5. Build and run the app:
   ```bash
   flutter run
   ```

### 4. Running the App
1. Open the App and sign in.
2. In the Setup View, enter the Server IP (e.g., `192.168.1.5` or `[2401:4900...]` for IPv6).
3. Set your **Camera ID** (e.g., `cam1`, `cam2`).
4. Click **Connect**.
5. Adjust your resolution based on your network speed (Settings ⚙️).
6. Press **GO LIVE**.

### 5. The Studio (OBS)
1. Open OBS Studio.
2. Add a new **Media Source**.
3. Uncheck "Local File".
4. Set the Input URL to: `rtmp://127.0.0.1:1935/userId_cam1` (replace `cam1` with your Camera ID).
5. Repeat for as many phones as you have!

---
*Built for zero-budget creators who demand massive production value.*
