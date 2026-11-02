#!/bin/sh
# Builds ui/dist and the dev bridge, then runs scripts/shots.ts with these arguments (its header lists them). Run on
# studio, from the repo's root, through scripts/studio.sh (docs/app.md, "Shots"):
#
#   scripts/studio.sh <you> --fetch build/shots -- sh ui/scripts/shots.sh --only shell --sizes desktop
#   scripts/studio.sh <you> -- env SMOKE=1 sh ui/scripts/shots.sh
#   scripts/studio.sh <you> --fetch build/shots -- env OMP=1 sh ui/scripts/shots.sh --only omp
set -eu

mkdir -p build
# vite alone: a type error elsewhere in a work in progress need not stop the pictures; `bun run build` is the gate.
# VITE_GALLERIES=1: the dev galleries, the in-page mock and `window.ompDev`, which a release build leaves out.
(cd ui && VITE_GALLERIES=1 bun x vite build >/dev/null)
(cd core && go build -ldflags="-X ompanion.app/core.Version=$(tr -d '[:space:]' < ../VERSION)" -o ../build/devbridge \
  ./cmd/devbridge)
# The licences page lists the core's Go modules as the Apple shells' pages do (core/cmd/licenses).
(cd core && go run ./cmd/licenses -ui ../ui/dist -target macos -target ios)
cd ui
exec bun scripts/shots.ts "$@"
