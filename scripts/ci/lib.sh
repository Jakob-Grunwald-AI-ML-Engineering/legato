#!/usr/bin/env bash
# Sourced by the CI scripts.

cd "$(git rev-parse --show-toplevel)" || exit 1

# 0 if the repo root holds a Swift package or Xcode project definition.
has_swift_targets() {
  [ -e Package.swift ] || [ -e project.yml ] || compgen -G "*.xcodeproj" > /dev/null
}
