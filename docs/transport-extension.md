# Future transports (not implemented)

Only one transport exists today: **VLESS + REALITY + XTLS Vision over TCP** (`reality-tcp`).
A CDN-fronted mode is possible future work. **None of it is implemented, nothing in the
installer or `xray-client` switches it on, and there is no hidden or inactive flag for it.**
An unsupported transport is an explicit error, not a dormant feature.

## What is prepared today

- Client identities (name, UUID, short id) are stored independently of how a profile is
  rendered. A new transport would add a renderer; it would not rewrite identities.
- Profiles already exported as `reality-tcp` URIs must keep working unchanged. The URI
  fixtures in `tests/fixtures/uri/` are the contract for that.
- State records the transport (`"transport": "reality-tcp"`), so an unknown value is
  rejected instead of guessed.

## What a CDN mode would be

A separate deployment, not a switch on the current one:

- WebSocket or XHTTP over TLS behind Cloudflare, instead of REALITY. REALITY presents
  another site's TLS handshake and cannot simply be put behind a CDN: the current
  REALITY server must not be "orange-clouded", and Vision settings do not carry over
  unchanged to WebSocket.
- A domain name, DNS and a certificate for the origin, with strict origin TLS.
- Client-version checks: not every client supports every transport.
- Cloudflare behavior to plan for: WebSocket is supported but the WAF handles the
  handshake, and idle connections can be reset at the edge. Cache, timeouts and WAF
  rules need review.
- A decision about the origin address: share TCP 443 through an origin reverse proxy, or
  use another address or port.
- A review of the CDN provider's usage policy for this kind of traffic.

## Limits of any claim

- CDN traffic is not "undetectable", and no transport here promises to resist blocking.
- This project has no live CDN, DNS, certificate or paid account, and requires none.
- Nothing here should be read as a promise that the future mode will be added.

References for the future design: Cloudflare WebSockets
(<https://developers.cloudflare.com/network/websockets/>) and the Xray XHTTP discussion
(<https://github.com/XTLS/Xray-core/discussions/4113>).
