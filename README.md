# Silk Chat launcher releases

This repository contains only signed macOS launcher artifacts for Silk Chat.
The application source and deployment configuration are private.

Each push to `main` verifies the Ed25519 signature of the staged manifest, checks
the artifact hashes against the private source commit, then publishes or
refreshes the rolling `launcher-latest` release:

- `launch.command`
- `webui.tar.gz`
- `silk-chat-proxy`
- `webui-version.txt`
- `manifest.txt`
- `manifest.txt.sig`

The installed app fetches these through Tor and verifies the same signature
before replacing its launcher or staging frontend/proxy resources for the next
launch.
