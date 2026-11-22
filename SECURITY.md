# Security Policy

## Supported versions

Only the latest release receives fixes. Please update to it before reporting an issue:
[Releases](https://github.com/phocean/studio-eq/releases).

## Reporting a vulnerability

Please **do not open a public issue** for a security problem. Report it privately through
GitHub instead: **Security › Report a vulnerability** on this repository
([direct link](https://github.com/phocean/studio-eq/security/advisories/new)).

Include what you can of:

- the Studio EQ version and macOS version;
- what an attacker can do, and under which conditions;
- steps to reproduce, or a proof of concept.

Studio EQ is maintained by one person in their spare time. You can expect an acknowledgement
within a week. Once a fix is released, the advisory is published with credit to you, unless
you prefer otherwise.

## Scope

Relevant reports include, for example:

- captured audio being written, kept or sent anywhere (Studio EQ must never record or transmit
  sound);
- a way to make Studio EQ mute or alter audio that is not headed to the Studio Display;
- a weakness in the sandbox, entitlements or Hardened Runtime of the distributed app;
- a published DMG whose signature or notarization does not match the source in this
  repository.

What the app is designed to do and its permissions are described in the
[README](README.md) and in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) (in French). The
"System Audio Recording" permission is required by macOS process taps and is not a
vulnerability in itself.
