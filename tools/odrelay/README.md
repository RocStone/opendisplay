# odrelay: the cable relay

Some VPN clients block every connection the sender opens over the direct
USB-C / Thunderbolt cable to a Mac receiver, yet let the receiver Mac
connect in. F5's client with "prohibit routing table changes" does this:
a direct dial waits forever ("No answer over the cable"), while a TCP
connection from the other Mac to this one goes through.

The relay turns the connection around. A small helper on the receiver Mac
keeps one connection open over the cable to the sender, and pipes it to the
receiver app on `127.0.0.1:9000` when a session wants it. The sender uses
that socket exactly as if it had dialed the receiver. Nothing else changes:
the official receiver app, the protocol inside, and the network settings on
both Macs stay as they are.

## What runs where

Sender (OpenDisplay, Connection set to **Cable**, a token installed):

- listens on the cable interfaces' link-local IPv6 addresses only, port 9010
  (any port if that one is taken), and advertises `_odrelay._tcp` there;
- dials the cable directly first, as always. A dial that has not answered
  after one second takes the relay's socket instead. The device row then
  says **Cable · via relay**;
- on the relay, tries the direct path every 30 seconds and moves the session
  there once it answers (the VPN went away).

Receiver Mac (`odrelay`, a per-user LaunchAgent):

- finds the sender by its Bonjour record on a cable interface, or else by
  trying every IPv6 neighbour on the cable at port 9010;
- connects and waits. When the sender takes the link, it answers the pairing
  challenge, opens the receiver on loopback and pipes both ways with
  `TCP_NODELAY`;
- reconnects within a second after a session ends, and backs off up to five
  seconds while the sender is unreachable.

The two Macs share a random token, so the sender only takes a relay it was
paired with. The handshake is an HMAC challenge on a fixed-length preamble
(`Mac/CableRelayWire.swift`): the token never crosses the cable.

Limits: one session at a time per receiver Mac. The receiver sees the relay
as a loopback connection, so it offers no power actions (Shut Down) over it,
and the UDP cursor channel stays off (the cursor rides the TCP stream).

## Install

From the sender Mac, with key-based ssh to the receiver Mac:

    tools/odrelay/install.sh <ssh-host>

This builds a universal `odrelay` here (no Xcode needed on the receiver
Mac), creates a token on this Mac if there is none, and on the receiver Mac
installs:

| What | Where |
| --- | --- |
| helper | `~/Library/Application Support/OpenDisplayRelay/odrelay` |
| token | `~/Library/Application Support/OpenDisplayRelay/token` (also on this Mac) |
| LaunchAgent | `~/Library/LaunchAgents/com.peetzweg.opensidecar.odrelay.plist` |
| log | `~/Library/Logs/OpenDisplayRelay.log` |

Run it again to update the helper; the token stays. OpenDisplay notices a
newly installed token by itself; it listens only while Connection is Cable.

Restart the helper on the receiver Mac with

    launchctl kickstart -k gui/$(id -u)/com.peetzweg.opensidecar.odrelay

## Uninstall

    tools/odrelay/install.sh --uninstall <ssh-host>

This stops and removes the LaunchAgent, the helper, its token and its log on
the receiver Mac, and the token on this Mac. Relaunch OpenDisplay afterwards.

## Testing

`defaults write com.peetzweg.opensidecar.mac cableRelayOnly -bool YES` (or
`-cableRelayOnly YES` at launch) makes Cable sessions skip the direct dial
and wait for the relay, to exercise it where the direct path works. Delete
the key to go back.

The sender logs `cable relay:` lines and `runs over the relay` to
`~/Library/Logs/OpenDisplay/opendisplay.log`; the helper logs to its own file.
