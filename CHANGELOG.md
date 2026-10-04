# Changelog

All notable changes to **mob_vision** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

---

## [0.1.2] - 2026-10-04

### Changed
- **Signed with the shared mob first-party plugin key** (MOB-390).
  `priv/mob_plugin.pub` is now the key shared by the other first-party
  `mob_*` plugins (fingerprint
  `ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=`), the same key as the other
  first-party plugins. Trust is still recorded per plugin name: map
  `mob_vision: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg="` in
  `config :mob, :trusted_plugins` or run `mix mob.plugin.trust mob_vision`. Hosts that
  recorded the old per-repo fingerprint for 0.1.1 will get a key-rotation
  error; re-run `mix mob.plugin.trust mob_vision` or switch the entry to the
  shared fingerprint.

## [0.1.1] - 2026-09-30

### Added
- **Signing public key now ships in the package** (`priv/mob_plugin.pub`,
  MOB-65). 0.1.0 was published without it, so no host could verify its
  signature. mob_vision is signed with its own key, not the shared key used by
  the other first-party `mob_*` plugins. Record trust with
  `mix mob.plugin.trust mob_vision`, or add
  `mob_vision: "ed25519:xQWce2LIF0VQ1nb/1clGoTY/YEGgl+Ew6Z15QM+XTpE="` to
  `config :mob, :trusted_plugins`. The fingerprint shared by the other
  first-party plugins will not match.

### Changed
- **Re-signed with plugin envelope v2** (MOB-287). mob_dev 0.7.2+ verifies
  this signature before evaluating the manifest. mob_dev 0.7.0 / 0.7.1 can't
  read v2 signatures and report this release as `invalid signature` —
  upgrade the host app to `{:mob_dev, "~> 0.7.2", only: :dev, runtime: false}`.
  No plugin code changes.

## [0.1.0] - 2026-07-05

### Added
- Initial release: on-device **OCR / text recognition** via `MobVision.recognize_text/3`.
  Recognizes text in a still image file — no camera, no network, no runtime
  permission. iOS uses the `Vision` framework (`VNRecognizeTextRequest`);
  Android uses ML Kit `text-recognition` (bundled Latin recognizer). Results
  arrive at `handle_info` as `{:vision, :text, text}` or `{:vision, :error, reason}`.
