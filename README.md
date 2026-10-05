# dav-remount

A small macOS agent that keeps a WebDAV share mounted in Finder across
sleep/wake, login, and VPN up/down. No UI, no cloud, no third-party driver.

## Why

Two things go wrong with WebDAV on a Mac:

- **Finder's built-in client (webdavfs) has no reconnect.** A share mounted
  before the lid closes is dead after it opens; the first app to touch it
  beachballs until the mount times out.
- **"Virtual drive" clients (File Provider based) serve a stale cache.** They
  list the share once and may never ask the server again; a file can show a
  fresh date and open with old content, or fail with "couldn't connect"
  without a single request leaving the machine.

`dav-remount` keeps the native mount, and does the one thing it lacks: it
notices the volume is gone or dead and mounts it again, quietly, after
checking that the server is actually reachable (LAN or VPN).

## What it does

- Runs as a per-user LaunchAgent in your login session.
- Triggers on **login/boot**, **wake from sleep** (IOKit power notification),
  **network change** (reachability callback), and a **poll** (every 5 min
  while mounted, every 30 s while not).
- **Ejects cleanly before sleep** so there is never a dead mount after wake.
  If something kept the volume busy, a hung listing after wake is detected
  and the mount is forced off and redone.
- **Reachability gate:** resolves the host and makes a TCP connect to it with
  a short timeout. Off VPN / off LAN it logs `unreachable` and does nothing.
  Optionally insists the address is internal (`expect_ip_prefix`) to catch a
  VPN that's down while public DNS still answers.
- **Mounts with Apple's own NetFS API** (what Finder uses), with UI
  suppressed, so no dialog can ever pop up.
- **Credential from the login Keychain.** `dav-remount set-token` stores your
  personal access token (or password) in an internet-password item that only
  this binary is allowed to read. Nothing secret is in the config or the repo.
- On an auth failure (revoked token) it backs off to one attempt per 30 s and
  logs once, instead of hammering the server.
- `dav-remount unmount --pause 60` ejects and tells the agent to leave it
  alone for an hour.

## Install

Requirements: macOS 13 or later. To build from source you need the Command
Line Tools (`xcode-select --install`); no Xcode.app.

```sh
git clone https://github.com/Brian-Gee2026/dav-remount.git
cd dav-remount
./build.sh        # → build/dav-remount
./install.sh      # prompts for share URL, username, and the token
```

Or download a release binary and run `./install.sh path/to/dav-remount`.

`install.sh` puts the binary in `~/.local/bin`, the config in
`~/.config/dav-remount/config`, the token in your login Keychain, and loads
`~/Library/LaunchAgents/dev.dav-remount.agent.plist`. It ends with
`dav-remount status`, which should show the share mounted.

## Configure

`~/.config/dav-remount/config` is `key = value`; see `config.example`.
Required: `url` (https share URL) and `user`. Everything else has defaults.

The credential is **never** in the config:

```sh
dav-remount set-token      # prompts, no echo; stores in Keychain
dav-remount forget-token
```

## Use

```
dav-remount status                 what it sees: reachability, token, mount
dav-remount once                   mount now if needed (exit 0 when healthy)
dav-remount unmount [--pause MIN]  eject; optionally pause the agent
dav-remount resume                 clear a pause
tail -f ~/Library/Logs/dav-remount.log
```

Reload/unload the agent:

```sh
launchctl kickstart -k gui/$(id -u)/dev.dav-remount.agent
launchctl bootout      gui/$(id -u)/dev.dav-remount.agent
```

## Troubleshooting

- **`unreachable: DNS failed`** — you're not on the LAN/VPN, or your resolver
  isn't the internal one. Nothing is wrong with the agent; it waits.
- **`server rejected the credential`** — token revoked or expired. Mint a new
  one and `dav-remount set-token`; the agent picks it up on the next poll.
- **A Keychain dialog appears after rebuilding** — the ad-hoc code signature
  changed, so the Keychain asks once whether the new binary may read the item.
  Click Always Allow. Avoid this by installing a release binary rather than
  rebuilding.
- **Volume name** — the last path component of the URL, or the host name when
  the share is served at the root (`https://dav.example.com/` →
  `/Volumes/dav.example.com`). Get the path right: a URL whose first listing
  returns 404 fails with `rc=19 (Operation not supported by device)`.
- **Volume mounted at `/Volumes/share-1`** — something else holds
  `/Volumes/share`. The agent tracks the volume by its server URL, not its
  path, so this is harmless.

## Uninstall

```sh
./uninstall.sh            # agent + binary; keeps config and token
./uninstall.sh --purge    # also removes config and the Keychain item
```

## Security notes

- The token is stored as a Keychain internet-password item scoped to this
  binary; it is read into memory only for the duration of a mount call.
- The config file is created `0600`; it holds only the URL and username.
- The agent never shows UI and never retries auth failures faster than once
  per 30 s.
- Server-side logging and authorization are the server's job; this is only a
  client.

MIT licensed.
