/// Represents the authoritative lifecycle state of the system tray integration.
enum SystemTrayState {
  /// Tray integration has not yet begun initialization.
  uninitialized,

  /// Tray initialization is actively in progress.
  initializing,

  /// System tray icon and menu are verified, functional, and ready.
  ready,

  /// Native symbols/libraries or OS tray capabilities are unavailable.
  unavailable,

  /// Initialization failed due to an unexpected unrecoverable error.
  failed;

  /// Whether the system tray is fully operational and safe to target for minimize/close.
  bool get isReady => this == SystemTrayState.ready;

  /// Whether tray integration could not be established.
  bool get isUnavailableOrFailed =>
      this == SystemTrayState.unavailable || this == SystemTrayState.failed;

  /// Whether the tray should be retried after a compatibility fallback or a failed init.
  bool get isRetryable =>
      this == SystemTrayState.unavailable || this == SystemTrayState.failed;
}
