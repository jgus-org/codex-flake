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
    in
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
          patches = (oldAttrs.patches or [ ]) ++ [ ./patches/shell-environment.patch ];
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
          buildAttr = "codex";
          buildFailureHash = "cargoHash";
          verification = "build";
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
              nix build --option post-build-hook "" --no-link "''${FLAKE_ROOT:-$PWD}#codex"
            '';
          };
          update-branches = flake-lib.lib.mkUpdateBranches {
            inherit pkgs source;
            pinSchema = "github";
          };
        };
        checks.codex = codex;
      });
}
