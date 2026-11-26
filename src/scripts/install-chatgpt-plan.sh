#!/bin/bash
# Install the official noncommercial devkit for this user's local OpenLink integration.
set -euo pipefail
revision=0a36fefeb913055c8c7a1a29b63d82b96b2e841a
base="$HOME/Library/Application Support/OpenLink Tuner"
target="$base/plan-sdk-$revision"
if [[ -f "$target/packages/local/dist/index.js" ]]; then exit 0; fi
mkdir -p "$base"
staging=$(mktemp -d "$base/.plan-install.XXXXXX")
trap 'rm -rf "$staging"' EXIT
git -C "$staging" init -q
git -C "$staging" fetch -q --depth 1 https://github.com/openai/sign-in-with-chatgpt-devkit.git "$revision"
git -C "$staging" checkout -q --detach FETCH_HEAD
cd "$staging"
npm ci --ignore-scripts --workspace @siwc/local --include-workspace-root --no-audit --no-fund
npm run build --workspace @siwc/local
test -f packages/local/dist/index.js
mv "$staging" "$target"
