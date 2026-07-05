# Changelog

All notable changes to **mob_vision** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

---

## [0.1.0] - 2026-07-05

### Added
- Initial release: on-device **OCR / text recognition** via `MobVision.recognize_text/3`.
  Recognizes text in a still image file — no camera, no network, no runtime
  permission. iOS uses the `Vision` framework (`VNRecognizeTextRequest`);
  Android uses ML Kit `text-recognition` (bundled Latin recognizer). Results
  arrive at `handle_info` as `{:vision, :text, text}` or `{:vision, :error, reason}`.
