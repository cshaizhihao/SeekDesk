SeekDesk bundled proxy core

Xray-core v26.11.9, macOS ARM64, unmodified upstream executable.
Project and corresponding source: https://github.com/XTLS/Xray-core/tree/v26.11.9
Official release: https://github.com/XTLS/Xray-core/releases/tag/v26.11.9
Archive: https://github.com/XTLS/Xray-core/releases/download/v26.11.9/Xray-macos-arm64-v8a.zip
License: Mozilla Public License 2.0 (see Xray-LICENSE.txt).

Verified upstream archive SHA-256:
233f0c66681cd0726f81a6b2b6ed6a5710869e312047b522e46ed53035bebd26
Extracted executable SHA-256 (before application code signing):
1b2d5ebe3a4c332203db24b81a052c6d6688a7f80705090f031b7416013ee1b2

The app signs its embedded helper during packaging; signing changes the file hash.
The helper accepts a generated JSON config over stdin and listens only on
127.0.0.1 with random per-launch HTTP proxy credentials. No TUN interface,
system proxy settings or other applications' network settings are changed.
No routing databases, default nodes, subscription services or shell scripts
are downloaded at runtime.
