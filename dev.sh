#!/usr/bin/sh

NPM_CONFIG_ALLOW_GIT=all npx github:http-party/http-server zig-out/web -p 8000  --header "Cross-Origin-Opener-Policy: same-origin" --header "Cross-Origin-Embedder-Policy: credentialless"
