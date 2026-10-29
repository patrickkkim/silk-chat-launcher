# Silk Chat launcher releases

This repository contains only signed macOS launcher artifacts for Silk Chat.
The application source and deployment configuration are private.

Each push to `main` verifies the Ed25519 signature and SHA-256 of the staged
launcher, then publishes or refreshes the rolling `launcher-latest` release:

- `launch.command`
- `manifest.txt`
- `manifest.txt.sig`

The installed app fetches these through Tor and verifies the same signature
before replacing its launcher.
