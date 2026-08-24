# FirstFew Swift SDK

Basic analytics for App Store apps — one call at launch, everything else is automatic.

```swift
import FirstFew

FirstFew.configure(
    token: "<your ingest token>",   // FirstFew ▸ product settings ▸ data services
    baseURL: URL(string: "https://your-firstfew-host")!
)
```

That single call automatically handles:

- `app_launch` on every launch and return to foreground (new / active user stats)
- Reinstall detection (`app_reinstall`; user identity survives reinstalls via Keychain)
- Device context: model, OS version, app version, language, region, timezone offset
- Apple Search Ads attribution reporting (AdServices token, iOS 14.3+)

React to Apple Search Ads attribution (optional — reporting itself is automatic):

```swift
FirstFew.attribution { result in
    if result["attribution"] as? Bool == true {
        // Search Ads user — extra fields (campaign_id, keyword_id, …) appear
        // when enabled in your FirstFew console. Cached across launches.
    }
}
```

Business events are one line each:

```swift
FirstFew.track("onboarding_completed")
FirstFew.track("pro_purchased", value: 9.99, currency: "USD")
```

Notes:

- The token is **write-only**: it can submit data, never read anything back.
- Events are queued on disk and retried with backoff; a `200` is the only dequeue signal. Tracking is fire-and-forget and never blocks or breaks the host app.
- No IDFA, no ATT prompt, no permission dialogs. Ships with a privacy manifest (`PrivacyInfo.xcprivacy`). Declare **User ID** and **Product Interaction** (analytics, not tracking) in your App Store privacy label.
- iOS 14+.
