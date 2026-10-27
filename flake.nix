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
      source = {
        owner = "openai";
        repo = "codex";
        tagPrefix = "rust-v";
        type = "github";
      };
      # A dotted name writes a nested pin attribute; an empty field is the updater's unresolved marker, so a re-run fills it.
      v8PinFields = [
        "v8.version"
        "v8.archive.aarch64-darwin"
        "v8.archive.aarch64-linux"
        "v8.archive.x86_64-linux"
        "v8.srcBinding.aarch64-darwin"
        "v8.srcBinding.aarch64-linux"
        "v8.srcBinding.x86_64-linux"
      ];
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
    flake-lib.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        orgFormatting = flake-lib.lib.mkFormatting {
          inherit self system;
        };
      in
      {
        checks.formatting = orgFormatting.check;
        formatter = orgFormatting.formatter;
        packages = rec {
          # The v8 crate links a prebuilt static archive and include!s a prebuilt source binding without checking
          # either version, so the pair comes from this pin's own instantiation, not the pair nixpkgs generated for
          # its own codex release. The `or` fallbacks keep an unresolved pair evaluable, because update-version
          # evaluates this package before it runs the artifact hook.
          codex =
            (pkgs.codex.override {
              librusty_v8 = pkgs.fetchurl {
                name = "librusty_v8-${pin.v8.version or ""}";
                sha256 = pin.v8.archive.${system} or "";
                url = "https://github.com/denoland/rusty_v8/releases/download/v${pin.v8.version or ""}/librusty_v8_release_${pkgs.stdenv.hostPlatform.rust.rustcTarget}.a.gz";
              };
              librusty_v8_src_binding = pkgs.fetchurl {
                name = "src_binding-${pin.v8.version or ""}";
                sha256 = pin.v8.srcBinding.${system} or "";
                url = "https://github.com/denoland/rusty_v8/releases/download/v${pin.v8.version or ""}/src_binding_release_${pkgs.stdenv.hostPlatform.rust.rustcTarget}.rs";
              };
            }).overrideAttrs
              (
                finalAttrs: oldAttrs: {
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
                  patches = (oldAttrs.patches or [ ]) ++ [ (shellPatchFor pin.version) ];
                  postPatch = (oldAttrs.postPatch or "") + ''
                    cat ${./tests/shell-environment.rs} >> shell-command/src/shell_detect.rs
                  '';
                  src = pkgs.fetchFromGitHub {
                    inherit (source) owner repo;
                    hash = pin.sourceHash;
                    rev = pin.sourceRev;
                  };
                }
              );
          default = codex;
          update-branches = flake-lib.lib.mkUpdateBranches {
            inherit pkgs source;
            extraHashes = v8PinFields;
            formatter = orgFormatting.formatter;
            minimumTrackingVersion = "0.162.0";
            pinSchema = "github";
            trackStableOnly = true;
          };
          update-version = flake-lib.lib.mkUpdateVersion {
            inherit pkgs source;
            artifactHook = ./artifact-hook.sh;
            buildFailureHash = "cargoHash";
            extraHashes = v8PinFields;
            formatter = orgFormatting.formatter;
          };
        };
      }
    );
}
