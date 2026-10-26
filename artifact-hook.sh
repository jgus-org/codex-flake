#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#gh nixpkgs#nix nixpkgs#coreutils --command bash

# flake-lib artifactHook. Invoked with NEW_REV / NEW_VERSION / FLAKE_ROOT / GH_OWNER / GH_REPO; prints v8Version (the rusty_v8 release the pinned codex source requires) and rewrites v8-assets.nix with that release's per-system archive and src_binding hashes. codex pins v8 exactly in codex-rs/Cargo.toml, and the v8 crate links the archive and include!s the binding without checking either version, so the pair has to be resolved from the source at NEW_REV rather than from whatever nixpkgs ships for its own codex release.

set -euo pipefail

V8_VERSION=$(gh api "/repos/${GH_OWNER}/${GH_REPO}/contents/codex-rs/Cargo.toml?ref=${NEW_REV}" \
  --jq '.content' | base64 -d | sed -n 's/^v8 = "=\([^"]*\)"/\1/p' | head -1)
if [[ -z "${V8_VERSION}" ]]; then
  echo "error: codex-rs/Cargo.toml at ${NEW_REV} carries no exact v8 pin" >&2
  exit 1
fi

RELEASE="https://github.com/denoland/rusty_v8/releases/download/v${V8_VERSION}"

sri_of() {
  nix hash convert --hash-algo sha256 --to sri \
    "$(nix-prefetch-url --type sha256 "${1}" 2>/dev/null | tail -1)"
}

# This flake's eachDefaultSystem systems, in the order nixfmt sorts attribute keys, each named with its rusty_v8 release asset target.
ARCHIVE_ASSETS=""
BINDING_ASSETS=""
for SYSTEM in aarch64-darwin aarch64-linux x86_64-linux; do
  case "${SYSTEM}" in
  aarch64-darwin) RUSTC_TARGET=aarch64-apple-darwin ;;
  aarch64-linux) RUSTC_TARGET=aarch64-unknown-linux-gnu ;;
  x86_64-linux) RUSTC_TARGET=x86_64-unknown-linux-gnu ;;
  esac
  ARCHIVE_ASSETS+="    ${SYSTEM} = \"$(sri_of "${RELEASE}/librusty_v8_release_${RUSTC_TARGET}.a.gz")\";\n"
  BINDING_ASSETS+="    ${SYSTEM} = \"$(sri_of "${RELEASE}/src_binding_release_${RUSTC_TARGET}.rs")\";\n"
done

{
  echo '# Auto-managed by `nix run .#update-version`. Manual edits will be overwritten by the next bump.'
  echo '{'
  echo '  archive = {'
  printf '%b' "${ARCHIVE_ASSETS}"
  echo '  };'
  echo '  srcBinding = {'
  printf '%b' "${BINDING_ASSETS}"
  echo '  };'
  echo "  version = \"${V8_VERSION}\";"
  echo '}'
} >"${FLAKE_ROOT}/v8-assets.nix"

echo "v8Version=${V8_VERSION}"
