#!/bin/sh

set -ex

zig test src/parsing.zig
zig fmt src
zig build
