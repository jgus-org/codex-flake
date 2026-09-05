{
  description = "Codex CLI version-bumped ahead of nixpkgs.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    flake-lib = {
      url = "github:jgus/flake-lib/v1";
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
        codex = pkgs.codex.overrideAttrs (finalAttrs: _: {
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
      in
      {
        packages = {
          inherit codex;
          default = codex;
          update-version = flake-lib.lib.mkUpdateVersion {
            inherit pkgs source;
            buildAttr = "codex";
            buildFailureHash = "cargoHash";
            verification = "evaluate";
          };
          update-branches = flake-lib.lib.mkUpdateBranches {
            inherit pkgs source;
            pinSchema = "github";
          };
        };
      });
}
