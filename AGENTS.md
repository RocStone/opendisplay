# Local macOS development

Keep the development app identities stable. macOS TCC associates Screen
Recording and Accessibility grants with the bundle identifier and signing
requirement; changing either creates stale or duplicate permission entries.

- Sender Debug bundle ID: `com.peetzweg.opensidecar.mac.debug`
- Receiver Debug bundle ID: `com.peetzweg.opensidecar.mac.receiver.debug`
- Keep Debug builds separate from the release bundle IDs.
- Build the sender into `build/Build/Products/Debug/OpenDisplay Dev.app` and
  launch it with `./run.sh`. The script normalizes an ad hoc build's designated
  requirement before launch. Do not rebuild or re-sign it after granting Screen
  Recording during a test session.
- If the Debug sender's permission row is stale, quit it, run
  `tccutil reset ScreenCapture com.peetzweg.opensidecar.mac.debug`, launch the
  unchanged app, use its Grant button, and restart it once.

The Intel receiver test host is available as `ssh imac`. Deploy the x86_64
Debug receiver to `~/Applications/OpenDisplay Receiver Dev.app`; do not replace
the release receiver app. A windowed receiver is sufficient for protocol,
encode, and decode validation. Use its fullscreen video window for end-to-end
latency, presentation, scaling, and visual-quality measurements.

# Fork release build

This fork ships the sender without Sparkle: upstream's appcast would replace
it with the official build. The Release sender keeps the release bundle ID,
so it inherits the official app's settings (UserDefaults), but it is signed
by a different identity, so Screen Recording, Accessibility and Local Network
must be granted again after it replaces the official app. Build it with a
real identity (no provisioning profile is needed):

    xcodebuild build -project OpenSidecar.xcodeproj -scheme OpenSidecarMac \
      -configuration Release -derivedDataPath build \
      DEVELOPMENT_TEAM=<team id> CODE_SIGN_STYLE=Manual \
      CODE_SIGN_IDENTITY="Apple Development: <name> (<id>)"

Never launch it next to a running official sender: same bundle ID, same
settings, and both would dial the same receivers.

The Connection setting (Automatic / Cable / WiFi, `Mac/ConnectionMethod.swift`)
pins a Bonjour dial to one local interface with
`.service(name:type:domain:interface:)` plus `requiredInterface`. That
resolves at once; a dial that only prohibits WiFi can wander onto a VPN's
utun interface and hang.

A VPN can make the cable unusable no matter how the dial is pinned. F5's
client with "prohibit routing table changes" deletes every route of an
interface that comes up while its tunnel is connected (IPv6 link-local and
multicast included) and routes 169.254/16 into its utun. A replugged USB-C
cable often comes back as a new interface (en4 → en8), so it hits this.
`route -n monitor` shows the VPN daemon's RTM_DELETEs; `netstat -rn -f inet6`
lacks `fe80::%enX/64` for the cable. Interfaces that were up when the VPN
connected keep their routes. The sender says so in the session row
(`CableDialTrouble` in `Mac/ConnectionMethod.swift`).
