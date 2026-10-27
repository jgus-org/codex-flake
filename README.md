# codex-flake

A Nix flake that builds [OpenAI's Codex CLI](https://github.com/openai/codex) at a pinned upstream revision, so a consumer can run a release newer than the one its own nixpkgs carries.

## What it publishes

`packages.<system>.codex` — the Codex CLI. `packages.<system>.default` is the same derivation.

The other outputs (`checks.*`, `formatter`, `update-version`, `update-branches`) belong to this repository's own development and release process; they are not a consumer interface.

## Consuming

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    codex = {
      url = "github:jgus-org/codex-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, codex, ... }: {
    packages.x86_64-linux.codex = codex.packages.x86_64-linux.codex;
  };
}
```

The package is built against this flake's own nixpkgs. Following your nixpkgs into the flake, as above, keeps the CLI's dependencies in the same package set as the rest of your system, and is what a NixOS system should do.

## What you get

- **Hosts**: `aarch64-linux`, `x86_64-linux` and `aarch64-darwin`.
- **Shell selection differs from upstream.** Upstream resolves the user's shell from the password database and ignores `SHELL`. This build reads a non-empty `SHELL` first and falls back to the password database, because `pw_shell` is unreliable on NixOS. Commands the CLI runs are therefore executed by the shell named in the environment, not the one recorded for the account.
- **`passthru.unpatched`** is the same release built without that shell patch. It exists so this flake's maintainer can tell whether upstream still needs the change; a consumer should use `codex`.

See [LICENSE.md](LICENSE.md) for licensing and copyright, and [NOTICE.md](NOTICE.md) for the terms of upstream and distributed artifacts.
