#!/bin/bash
set -euo pipefail

usage() {
  echo "Usage: ./scripts/dev-mac.sh [--setup-only | --install]"
  echo "  --setup-only  Prepare the pinned Node.js and npm versions, then exit."
  echo "  --install     Reinstall project dependencies before launching development mode."
}

if [[ $# -eq 1 && $1 == --help ]]; then
  usage
  exit 0
fi
if [[ $# -gt 1 || ( $# -eq 1 && $1 != --setup-only && $1 != --install ) ]]; then
  usage >&2
  exit 2
fi
if [[ $(uname -s) != Darwin || $(uname -m) != arm64 ]]; then
  echo "Run this script from a native Apple Silicon macOS terminal." >&2
  exit 1
fi

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
node_version=$(cat .node-version)
npm_pin=$(/usr/bin/plutil -extract packageManager raw -o - package.json)
if [[ ! $node_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! $npm_pin =~ ^npm@[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Expected exact versions in .node-version and package.json's packageManager." >&2
  exit 1
fi
npm_version=${npm_pin#npm@}
cache_dir="$PWD/.tmp/dev-toolchain"
toolchain="$cache_dir/node-$node_version-npm-$npm_version-darwin-arm64"

if [[ ! -d $toolchain ]]; then
  echo "Preparing Node.js $node_version and npm $npm_version in $cache_dir"
  mkdir -p "$cache_dir"
  staging=$(mktemp -d "$cache_dir/install.XXXXXXXX")
  trap 'rm -rf -- "$staging"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  archive="node-v$node_version-darwin-arm64.tar.gz"
  distribution="https://nodejs.org/dist/v$node_version"
  curl -fsSL --retry 2 "$distribution/SHASUMS256.txt" -o "$staging/SHASUMS256.txt"
  curl -fsSL --retry 2 "$distribution/$archive" -o "$staging/$archive"
  (
    cd -- "$staging"
    awk -v archive="$archive" '$2 == archive { print }' SHASUMS256.txt > checksum.txt
    shasum -a 256 --check checksum.txt
  )
  mkdir "$staging/toolchain"
  tar -xzf "$staging/$archive" -C "$staging/toolchain" --strip-components=1
  (
    export PATH="$staging/toolchain/bin:$PATH"
    npm install --global --prefix "$staging/toolchain" --registry https://registry.npmjs.org "$npm_pin"
    [[ $(node --version) == "v$node_version" && $(npm --version) == "$npm_version" ]]
  )

  # Publish only after installation succeeds. Another invocation can finish first.
  "$staging/toolchain/bin/node" -e '
    const { renameSync } = require("node:fs");
    const [source, destination] = process.argv.slice(1);
    try {
      renameSync(source, destination);
    } catch (error) {
      if (!["EEXIST", "ENOTEMPTY"].includes(error.code)) throw error;
    }
  ' "$staging/toolchain" "$toolchain"
  rm -rf -- "$staging"
  trap - EXIT INT TERM
fi

if [[ $("$toolchain/bin/node" --version) != "v$node_version" ||
      $(PATH="$toolchain/bin:$PATH" "$toolchain/bin/npm" --version) != "$npm_version" ]]; then
  echo "The cached toolchain at $toolchain failed version verification." >&2
  exit 1
fi
export PATH="$toolchain/bin:$PATH"
echo "Using Node.js $node_version and npm $npm_version from $toolchain/bin"

if [[ ${1:-} == --setup-only ]]; then
  exit 0
fi

# Homebrew's rustup can be available without Cargo's proxy on PATH.
if ! command -v cargo >/dev/null && command -v rustup >/dev/null; then
  cargo_path=$(rustup which cargo)
  export PATH="$PATH:$(dirname -- "$cargo_path")"
fi

if [[ ${1:-} == --install || ! -f node_modules/vite/bin/vite.js ]]; then
  npm ci
fi

# Keep the native build's SDK aligned with the Xcode selected by xcrun.
if [[ -z ${SDKROOT:-} ]] && sdk_path=$(xcrun --sdk macosx --show-sdk-path 2>/dev/null); then
  export SDKROOT="$sdk_path"
fi

exec npm run dev
