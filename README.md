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
- StoreKit transaction reporting (iOS 15+): the device's purchase history, one row per
  original transaction, is sent after launch, on return to foreground and whenever StoreKit
  delivers a new transaction — purchases that carry no `appAccountToken` (offer codes
  redeemed on the App Store, family sharing, restores) are still attributed to the user,
  and orders show up in the console even without App Store Server Notifications

React to Apple Search Ads attribution (optional — reporting itself is automatic):

```swift
FirstFew.attribution { result in
    if result["attribution"] as? Bool == true {
        // Search Ads user — extra fields (campaign_id, keyword_id, …) appear
        // when enabled in your FirstFew console. Cached across launches.
    }
}
```

Collect the remote-push (APNs) device token — one more parameter, no other code:

```swift
FirstFew.configure(token: "<your ingest token>", baseURL: url, push: true)
```

With `push: true` the SDK registers the app for remote notifications and picks the
device token up by itself. The token is reported together with the APNs environment
(sandbox / production) and the user's notification permission, and again whenever
either changes. A `didRegisterForRemoteNotificationsWithDeviceToken` handler the app
already has — its own or another SDK's — keeps receiving the token, and a SwiftUI app
needs no app delegate for this. Two things stay with you:

- Add the **Push Notifications** capability to the app target (Signing & Capabilities).
  Without it the system rejects the registration and no token is collected.
- Asking the user to allow notifications. The SDK never shows the permission prompt;
  a token is collected either way, but a notification sent to it is only shown once
  the user has allowed notifications.

`push` is off by default, and then the SDK does not touch the app delegate at all. To
collect the token without the SDK hooking the delegate, leave it off and forward the
token yourself:

```swift
func application(_ application: UIApplication,
                 didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    FirstFew.setPushToken(deviceToken)
}
```

Business events are one line each:

```swift
FirstFew.track("onboarding_completed")
FirstFew.track("pro_purchased", value: 9.99, currency: "USD")
```

If the app has its own account system, bind your user id after login ("identify") —
the FirstFew console becomes searchable by your ids and devices of the same
account are grouped:

```swift
FirstFew.identify("your-account-id")   // after login / account switch
FirstFew.identify(nil)                 // on logout
```

For paid apps, pass the FirstFew user id as `appAccountToken` when starting a
StoreKit 2 purchase — App Store Server Notifications then carry it on every
transaction (first purchase, renewals, refunds), so revenue ties back to the
user and to the Search Ads keyword that acquired them:

```swift
let result = try await product.purchase(options: [
    .appAccountToken(FirstFew.appAccountToken ?? UUID())
])
```

If your purchases already pass your own account UUID as `appAccountToken`, keep
it — just make sure the same id is bound via `FirstFew.identify`.

Notes:

- The token is **write-only**: it can submit data, never read anything back.
- Events are queued on disk and retried with backoff; a `200` is the only dequeue signal. Tracking is fire-and-forget and never blocks or breaks the host app.
- No IDFA, no ATT prompt, no permission dialogs. Ships with a privacy manifest (`PrivacyInfo.xcprivacy`). Declare **User ID** and **Product Interaction** (analytics, not tracking) in your App Store privacy label; if you collect the push token, also **Device ID** (app functionality, not tracking).
- iOS 14+.
