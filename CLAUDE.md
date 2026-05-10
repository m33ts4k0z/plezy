# plezy

## Build & deploy

- When asked to push a build to a connected Android phone for testing,
  always build a **debug** APK (`flutter build apk --debug`) and install
  it via `adb -s <serial> install -r -d build/app/outputs/flutter-apk/app-debug.apk`.
  Release builds are unsigned in this repo and fail to install with
  `INSTALL_PARSE_FAILED_NO_CERTIFICATES`.
