%{
  name: :mob_vision,
  mob_version: "~> 0.7",
  plugin_spec_version: 1,
  description: "On-device OCR / text recognition (iOS Vision, Android ML Kit)",
  nifs: [
    # iOS: Objective-C NIF — the Vision framework (VNRecognizeTextRequest) run
    # on a CGImage loaded from the file path. lang: :objc -> compiled -fobjc-arc;
    # platform: :ios so it isn't pulled into the Android build.
    %{module: :mob_vision_nif, native_dir: "priv/native/ios", lang: :objc, platform: :ios},
    # Android: zig NIF bridging to io.mob.vision.MobVisionBridge (ML Kit
    # text-recognition via InputImage.fromFilePath) — no camera, no activity.
    %{module: :mob_vision_nif, native_dir: "priv/native/jni", lang: :zig, platform: :android}
  ],
  # No top-level :permissions capability and no android :permissions — image
  # OCR reads a file the app already has, so it needs no runtime permission and
  # no camera. (The planned live-camera scan_text mode will add the :camera
  # dependency on mob_camera; it isn't part of this release.)
  android: %{
    bridge_kt: "priv/native/android/MobVisionBridge.kt",
    bridge_class: "io.mob.vision.MobVisionBridge",
    # ML Kit's bundled Latin text recognizer. On-device, no Play Services
    # download required (the model ships in the artifact). Set-unioned + de-duped
    # into the host build.gradle by the native merge.
    gradle_deps: [
      "com.google.mlkit:text-recognition:16.0.1"
    ]
  },
  # Vision (VNRecognizeTextRequest); UIKit/CoreGraphics are implicit for loading
  # the image. No plist_keys — no camera or photo-library access here (the caller
  # supplies a path it already owns).
  ios: %{frameworks: ["Vision"]}
}
