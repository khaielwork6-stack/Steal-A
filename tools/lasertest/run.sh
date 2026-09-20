#!/usr/bin/env bash
# Offline (no Studio) tests of the laser rework's PURE shared modules:
#   client.luau  the client-side hit pipeline - a runner at 100/260/300 studs/s and
#                60/120/240/30/15/10 fps crossing every beam kind of all 24
#                generated rooms must always register (and a crouched body must
#                pass under a high beam); moving beams by the server clock; the
#                shared flight path leaves through the door from anywhere in
#                every room; the body silhouette.
#   routes.luau  the generator + fairness validator for all 24 rooms.
# Usage: tools/lasertest/run.sh [client|routes]      (needs `luau` from Rokit)
# The plain luau CLI has no Vector3 / CFrame: shim.luau is a minimal Vector3,
# and the modules under test are copied to a temp folder with it prepended.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Config" "$WORK/Util"
cp "$HERE/shim.luau" "$WORK/shim.luau"
cp "$ROOT/src/shared/Config/LaserConfig.luau" "$WORK/Config/LaserConfig.luau"
{
  echo 'local __s = require("../shim"); local Vector3, Vector2 = __s.Vector3, __s.Vector2'
  cat "$ROOT/src/shared/Util/LaserGeometry.luau"
} > "$WORK/Util/LaserGeometry.luau"
{
  echo 'local script = { Parent = { Config = { LaserConfig = "./Config/LaserConfig" }, Util = { LaserGeometry = "./Util/LaserGeometry" } } }'
  cat "$ROOT/src/shared/LaserPatterns.luau"
} > "$WORK/LaserPatterns.luau"
{
  echo 'local __s = require("./shim"); local Vector3 = __s.Vector3'
  echo 'local script = { Parent = { Config = { LaserConfig = "./Config/LaserConfig" } } }'
  cat "$ROOT/src/shared/LaserFlight.luau"
} > "$WORK/LaserFlight.luau"
cp "$HERE/${1:-client}.luau" "$WORK/test.luau"
if [ -d "$HOME/.rokit/bin" ]; then export PATH="$HOME/.rokit/bin:$PATH"; fi
# From the repository root: Rokit resolves `luau` through the project manifest.
cd "$ROOT"
luau "$WORK/test.luau"
