#!/bin/sh

set -ex

zig fmt src
zig build
