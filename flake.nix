{
  description = "Codex CLI version-bumped ahead of nixpkgs.";

  inputs = {
    flake-lib.url = "github:jgus-org/flake-lib/v1";
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    {
      self,
      flake-lib,
      nixpkgs,
      ...
    }:
    let
      pin = import ./pin.nix;
      v8Assets = import ./v8-assets.nix;
      source = {
        owner = "openai";
        repo = "codex";
        tagPrefix = "rust-v";
        type = "github";
      };
      # codex reads the login shell from the passwd DB (getpwuid_r) and ignores $SHELL, which is wrong on NixOS where
      # pw_shell is unreliable. Both patches prepend a $SHELL early-return to get_user_shell_path; upstream rewrote that
      # function to delegate to a get_user_path helper in the 0.163.0 line, so the hunk's anchor differs by version. nix's
      # compareVersions ranks 0.163.0 prereleases above 0.163.0, so >=0.163.0 selects the new hunk across that line.
      shellPatchFor =
        version:
        if
          flake-lib.lib.versionMatchesComparison version {
            operator = ">=";
            version = "0.163.0";
          }
        then
          ./patches/shell-environment.get-user-path.patch
        else
          ./patches/shell-environment.patch;
    in
    assert shellPatchFor "0.162.1" == ./patches/shell-environment.patch;
    assert shellPatchFor "0.163.0" == ./patches/shell-environment.get-user-path.patch;
    assert shellPatchFor "0.163.0-alpha.5" == ./patches/shell-environment.get-user-path.patch;
    # The artifact hook writes the pin's v8Version and v8-assets.nix from the same run, so a pair naming different
    # rusty_v8 releases is a partial update: the archive and the binding would come from different releases.
    assert v8Assets.version == pin.v8Version;
    flake-lib.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        orgFormatting = flake-lib.lib.mkFormatting {
          inherit self system;
        };
        # nixpkgs generates its librusty_v8 pair from the Cargo.lock of its own codex release, so a pin naming that
        # same release inherits the pair its source asks for. Any other pin carries the pair its own source asks for.
        codexBase =
          if pkgs.codex.version == pin.version then
            pkgs.codex
          else
            pkgs.codex.override (
              import ./v8.nix {
                inherit (pkgs)
                  fetchurl
                  lib
                  stdenv
                  ;
              } v8Assets
            );
        unpatched = codexBase.overrideAttrs (
          finalAttrs: _: {
            inherit (pin) version;
            cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
              inherit (finalAttrs)
                pname
                sourceRoot
                src
                version
                ;
              hash = pin.cargoHash or "";
            };
            src = pkgs.fetchFromGitHub {
              inherit (source) owner repo;
              hash = pin.sourceHash;
              rev = pin.sourceRev;
            };
          }
        );
        codex = unpatched.overrideAttrs (oldAttrs: {
          # nixpkgs disables the full suite because it needs networking and host services. Run only the isolated process-shell cases here.
          cargoTestFlags = [
            "--package"
            "codex-shell-command"
            "--lib"
            "process_shell_tests"
          ];
          checkPhase = ''
            set -o pipefail
            {
              ${oldAttrs.checkPhase or "cargoCheckHook"}
            } 2>&1 | tee shell-environment-tests.log
            grep -Fq 'test result: ok. 5 passed; 0 failed;' shell-environment-tests.log
          '';
          doCheck = true;
          passthru = (oldAttrs.passthru or { }) // {
            # Advisory canaries compare the package without this workaround; a patched build cannot prove that upstream no longer needs it.
            inherit unpatched;
          };
          patches = (oldAttrs.patches or [ ]) ++ [ (shellPatchFor pin.version) ];
          postPatch = (oldAttrs.postPatch or "") + ''
            cat ${./tests/shell-environment.rs} >> shell-command/src/shell_detect.rs
          '';
        });
        updateVersion = flake-lib.lib.mkUpdateVersion {
          inherit pkgs source;
          artifactHook = ./artifact-hook.sh;
          buildFailureHash = "cargoHash";
          extraHashes = [ "v8Version" ];
          formatter = orgFormatting.formatter;
        };
      in
      {
        checks = {
          codex = codex;
          formatting = orgFormatting.check;
          # Proves the version range against the two real upstream source shapes: the pinned hunk applies only to the
          # pre-0.163.0 source, the get_user-path hunk only to the refactored one. Fails if either patch stops matching the
          # shape its range assigns it, which is exactly the drift that broke the 0.163.0 alphas.
          shell-environment-patch =
            pkgs.runCommand "codex-shell-environment-patch"
              {
                nativeBuildInputs = [ pkgs.patch ];
                newSrc = pkgs.fetchurl {
                  hash = "sha256-iTOQeb6KnbxmKHo1VbnOlHDLh4VHqoWZeP5HfV6fpdk=";
                  url = "https://raw.githubusercontent.com/openai/codex/rust-v0.163.0-alpha.1/codex-rs/shell-command/src/shell_detect.rs";
                };
                oldSrc = pkgs.fetchurl {
                  hash = "sha256-e749DA+D3C4KfK3H7SLuDNndz9xyWmsYub3acpXB2Uo=";
                  url = "https://raw.githubusercontent.com/openai/codex/rust-v0.162.1/codex-rs/shell-command/src/shell_detect.rs";
                };
              }
              ''
                set -euo pipefail
                applies() { rm -rf w && mkdir -p w/shell-command/src && cp "$1" w/shell-command/src/shell_detect.rs && ( cd w && patch -p1 --dry-run -i "$2" >/dev/null ); }
                applies "$oldSrc" ${./patches/shell-environment.patch}
                if applies "$newSrc" ${./patches/shell-environment.patch}; then
                  echo "expected the pre-refactor hunk to fail on the 0.163.0 source" >&2; exit 1
                fi
                applies "$newSrc" ${./patches/shell-environment.get-user-path.patch}
                if applies "$oldSrc" ${./patches/shell-environment.get-user-path.patch}; then
                  echo "expected the 0.163.0 hunk to be source-specific" >&2; exit 1
                fi
                touch $out
              '';
        };
        formatter = orgFormatting.formatter;
        packages = {
          inherit codex;
          default = codex;
          update-branches = flake-lib.lib.mkUpdateBranches {
            inherit pkgs source;
            extraBranchOwnedFiles = [ "v8-assets.nix" ];
            extraHashes = [ "v8Version" ];
            formatter = orgFormatting.formatter;
            minimumTrackingVersion = "0.162.0";
            pinSchema = "github";
            trackStableOnly = true;
          };
          update-version = pkgs.writeShellApplication {
            name = "update-version";
            runtimeInputs = [ pkgs.nix ];
            text = ''
              ${pkgs.lib.getExe updateVersion} "$@"
              # flake-lib's unchanged-source shortcut only evaluates. Verify patches before update-branches can publish this version, including specification-only changes.
              nix build --no-link "''${FLAKE_ROOT:-$PWD}#codex"
            '';
          };
        };
      }
    );
}
