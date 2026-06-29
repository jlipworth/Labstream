public enum PMSKit {
    /// Library fallback only — the app overrides this by passing the bundle
    /// `CFBundleShortVersionString` (= `MARKETING_VERSION`) into `ClientIdentity`.
    /// Keep in sync with `MARKETING_VERSION` in VisionPlay.xcodeproj when bumping the app version.
    public static let version = "1.3.5"
}
