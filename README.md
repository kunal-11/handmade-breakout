# Handmade Breakout

A simple breakout in zig to try out software rendering, web assembly. Supports 2 platforms -
1. Web - wasm deployed as static files
2. SDL - native build

## Overview

The design is inspired by Handmade Hero.
The game is compiled a separate library and loaded by browser (wasm) or SDL platform (dll).
Platform contract is defined in src/api.zig.
1. Frame buffer (Screen)
2. Inputs
3. Memory (permanent and transient)
4. File Reading for asset loading
5. Work queue for multi threading

platform calls updateAndRender at specified frame intervals and the game writes to the frame buffer.

## Build Run

```sh
# web build
zig build web -Doptimize=ReleaseSmall

# start static file server on localhost:8000
./dev.sh

# native shared lib build
zig build lib -Doptimize=ReleaseSafe

# run native SDL3 exe
zig build run -Doptimize=ReleaseSafe

# pack assets if new are added
zig build pack
```
