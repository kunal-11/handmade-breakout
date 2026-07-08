# Handmade Breakout

A simple breakout in zig to try out software rendering, web assembly. Supports 2 platforms -
1. Web - wasm deployed as static files
2. SDL - native build

No libraries used apart for SDL in platform for native windowing/audio.

## Overview

The design is inspired by Handmade Hero.
The game is compiled a separate library and loaded by browser (wasm) or SDL platform (dll). Platform contract is defined in src/api.zig
1. Frame buffer (Screen)
2. Inputs
3. Memory (permanent and transient)
4. File Reading for asset loading
5. Work queue for multi threading

It calls updateAndRender at specified frame intervals and the game updates the frame buffer.

## Build Run

1. Web

build wasm -
zig build web -Doptimize=ReleaseSmall

start static file server -
./dev.sh

runs on http://localhost:8000

2. Native

build dylib -
zig build lib -Doptimize=ReleaseSafe

run the SDL -
zig build run -Doptimize=ReleaseSafe

3. Asset packer

if any new assets are added, update the packfile -
zig build pack

