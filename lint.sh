#!/bin/sh

set -ex

zig build test --summary failures
zig fmt src
zig build
