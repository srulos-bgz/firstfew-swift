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

## FirstFew Forward (optional)

Give the app its FirstFew URL scheme — `ff` followed by its App Store ID, e.g.
`ff6478123456` — under **URL Types** in Info.plist, and hand the SDK every URL
the app is opened with:

```swift
// UIKit (app delegate)
func application(_ app: UIApplication, open url: URL,
                 options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
    if FirstFew.handle(url) { return true }
    // …your own URL handling
    return false
}

// SwiftUI
.onOpenURL { url in FirstFew.handle(url) }
```

`handle` claims the links in this scheme and returns `false` for everything else.
Web pages and other apps can now open the app with `ff<id>://…`, and a link can
carry the device's FirstFew identity on to a next address:

```
ff6478123456://forward?forwardUrl=https://example.com/support&app_version&language
   → https://example.com/support?ff_id=<FirstFew user id>&ff_app_version=2.4.1%20(87)&ff_language=zh-Hans-CN

ff6478123456://forward?forwardUrl=otherapp://open
   → otherapp://open?ff_id=<FirstFew user id>

ff6478123456://forward
   → just opens the app
```

The app opens and goes straight on to `forwardUrl` — an `https` page (in Safari)
or another app's URL scheme — with the FirstFew user id appended as `ff_id`: the
stable id the SDK gives the user on first launch (kept in the Keychain, survives
reinstalls; the `user_id` on every event, `FirstFew.userId` in code, the id the
console shows). After it come the device values the link lists by name, each as
`ff_<name>` — `ff_external_id` (bound with `identify`), `ff_app_version`,
`ff_os_version`, `ff_device_model`, `ff_language`, `ff_country`; the link only
says which values to take, the keys are fixed, and the `ff_` prefix keeps them
apart from whatever parameters the target already has. Every handled link is
reported as the reserved event `link_open` (with the target's scheme and host as
`to`; never its query).

Anyone can craft a link in this scheme (this SDK is open source), so the app only
forwards to addresses on the product's **FirstFew Forward allowlist** in the
FirstFew console (product settings ▸ product management: domains such as
`example.com` — matched exactly, so `www.example.com` is a separate entry — other
apps' schemes such as `otherapp://`, or both as `https://example.com`). The list
stays on the server — this is the one request the SDK makes before acting on
anything: right before opening, it sends the target's scheme and host and gets
back allowed / not allowed. The SDK waits up to 60 seconds for that answer, retrying
while the app is in front of the user — so a link that cold-starts a freshly
installed app still forwards once the user has answered the first-launch network
permission prompt (mainland-China devices). Past that, or with an empty list, the
link just opens the app. Nothing else (launches, events) ever triggers that
request.

### Forwarding to another FirstFew app

Point `forwardUrl` at the other app's scheme (`ff` + its App Store ID) and put that
scheme on your allowlist. On the receiving side, `handle` claims the link and
returns `true`; the values are read straight from the URL — `ff_id` is the sender's
FirstFew user id, the other `ff_*` parameters are the device values the sender took along:

```swift
// Sender: ff6478123456://forward?forwardUrl=ff1122334455://open&language
//   → opens ff1122334455://open?ff_id=<sender's FirstFew user id>&ff_language=zh-Hans-CN

// Receiver (ff1122334455)
.onOpenURL { url in
    guard FirstFew.handle(url) else { return }
    let params = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let senderId = params.first { $0.name == "ff_id" }?.value
    let language = params.first { $0.name == "ff_language" }?.value
}
```

Keep in mind: a custom scheme only works while the app is installed (nothing
happens otherwise); Safari asks "Open in …?" first, and most in-app browsers block
custom schemes. Percent-encode `forwardUrl` when the address has its own query
string.

Notes:

- The token is **write-only**: it can submit data, never read anything back (the one exception is the yes/no answer to "may this FirstFew link forward there?", which never returns the allowlist itself).
- Events are queued on disk and retried with backoff; a `200` is the only dequeue signal. Tracking is fire-and-forget and never blocks or breaks the host app.
- No IDFA, no ATT prompt, no permission dialogs. Ships with a privacy manifest (`PrivacyInfo.xcprivacy`). Declare **User ID** and **Product Interaction** (analytics, not tracking) in your App Store privacy label; if you collect the push token, also **Device ID** (app functionality, not tracking).
- iOS 14+.
