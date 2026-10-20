{
  description = "Codex CLI version-bumped ahead of nixpkgs.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    flake-lib = {
      url = "github:jgus-org/flake-lib/v1";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
  };

  outputs = { nixpkgs, flake-utils, flake-lib, ... }:
    let
      pin = import ./pin.nix;
      source = {
        type = "github";
        owner = "openai";
        repo = "codex";
        tagPrefix = "rust-v";
      };
      # codex reads the login shell from the passwd DB (getpwuid_r) and ignores $SHELL, which is wrong on NixOS where
      # pw_shell is unreliable. Both patches prepend a $SHELL early-return to get_user_shell_path; upstream rewrote that
      # function to delegate to a get_user_path helper in the 0.163.0 line, so the hunk's anchor differs by version. nix's
      # compareVersions ranks 0.163.0 prereleases above 0.163.0, so >=0.163.0 selects the new hunk across that line.
      shellPatchFor = version:
        if flake-lib.lib.versionMatchesComparison version {
          operator = ">=";
          version = "0.163.0";
        }
        then ./patches/shell-environment.get-user-path.patch
        else ./patches/shell-environment.patch;
    in
    assert shellPatchFor "0.162.1" == ./patches/shell-environment.patch;
    assert shellPatchFor "0.163.0" == ./patches/shell-environment.get-user-path.patch;
    assert shellPatchFor "0.163.0-alpha.5" == ./patches/shell-environment.get-user-path.patch;
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        unpatched = pkgs.codex.overrideAttrs (finalAttrs: _: {
          inherit (pin) version;
          src = pkgs.fetchFromGitHub {
            inherit (source) owner repo;
            rev = pin.sourceRev;
            hash = pin.sourceHash;
          };
          cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
            inherit (finalAttrs) pname version src sourceRoot;
            hash = pin.cargoHash or "";
          };
        });
        codex = unpatched.overrideAttrs (oldAttrs: {
          patches = (oldAttrs.patches or [ ]) ++ [ (shellPatchFor pin.version) ];
          postPatch = (oldAttrs.postPatch or "") + ''
            cat ${./tests/shell-environment.rs} >> shell-command/src/shell_detect.rs
          '';
          doCheck = true;
          # nixpkgs disables the full suite because it needs networking and host services. Run only the isolated process-shell cases here.
          cargoTestFlags = [ "--package" "codex-shell-command" "--lib" "process_shell_tests" ];
          checkPhase = ''
            set -o pipefail
            {
              ${oldAttrs.checkPhase or "cargoCheckHook"}
            } 2>&1 | tee shell-environment-tests.log
            grep -Fq 'test result: ok. 5 passed; 0 failed;' shell-environment-tests.log
          '';
          passthru = (oldAttrs.passthru or { }) // {
            # Advisory canaries compare the package without this workaround; a patched build cannot prove that upstream no longer needs it.
            inherit unpatched;
          };
        });
        updateVersion = flake-lib.lib.mkUpdateVersion {
          inherit pkgs source;
          buildFailureHash = "cargoHash";
        };
      in
      {
        packages = {
          inherit codex;
          default = codex;
          update-version = pkgs.writeShellApplication {
            name = "update-version";
            runtimeInputs = [ pkgs.nix ];
            text = ''
              ${pkgs.lib.getExe updateVersion} "$@"
              # flake-lib's unchanged-source shortcut only evaluates. Verify patches before update-branches can publish this version, including specification-only changes.
              nix build --no-link "''${FLAKE_ROOT:-$PWD}#codex"
            '';
          };
          update-branches = flake-lib.lib.mkUpdateBranches {
            minimumTrackingVersion = "0.162.0";
            trackStableOnly = true;
            inherit pkgs source;
            pinSchema = "github";
          };
        };
        checks.codex = codex;
        # Proves the version range against the two real upstream source shapes: the pinned hunk applies only to the
        # pre-0.163.0 source, the get_user-path hunk only to the refactored one. Fails if either patch stops matching the
        # shape its range assigns it, which is exactly the drift that broke the 0.163.0 alphas.
        checks.shell-environment-patch = pkgs.runCommand "codex-shell-environment-patch" {
          nativeBuildInputs = [ pkgs.patch ];
          oldSrc = pkgs.fetchurl {
            url = "https://raw.githubusercontent.com/openai/codex/rust-v0.162.1/codex-rs/shell-command/src/shell_detect.rs";
            hash = "sha256-e749DA+D3C4KfK3H7SLuDNndz9xyWmsYub3acpXB2Uo=";
          };
          newSrc = pkgs.fetchurl {
            url = "https://raw.githubusercontent.com/openai/codex/rust-v0.163.0-alpha.1/codex-rs/shell-command/src/shell_detect.rs";
            hash = "sha256-iTOQeb6KnbxmKHo1VbnOlHDLh4VHqoWZeP5HfV6fpdk=";
          };
        } ''
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
      });
}
