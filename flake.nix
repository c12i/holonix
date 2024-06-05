{
  # flake format https://nixos.org/manual/nix/stable/command-ref/new-cli/nix3-flake.html#flake-format
  description = "Holonix - Holochain Nix flake";

  # specify all input dependencies needed to create the outputs of the flake
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";

    # utility to iterate over multiple target platforms
    flake-parts.url = "github:hercules-ci/flake-parts";

    # lib to build a nix package from a rust crate
    crane = {
      url = "github:ipetkov/crane";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Rust toolchain
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Holochain sources
    holochain = {
      url = "github:holochain/holochain/main";
      flake = false;
    };

    # Lair keystore sources
    lair-keystore = {
      url = "github:holochain/lair/lair_keystore-v0.4.4";
      flake = false;
    };

    # Holochain Launch CLI
    hc-launch = {
      url = "github:holochain/launcher/holochain-weekly";
      flake = false;
    };

    hc-scaffold = {
      url = "github:holochain/scaffolding/holochain-weekly";
      flake = false;
    };

    holonix-default = {
      path = "templates/default";
      description = "Holonix default template";
    };
  };

  # outputs that this flake should produce
  outputs = inputs @ { self, nixpkgs, flake-parts, rust-overlay, crane, ... }:
    # refer to flake-parts docs https://flake.parts/
    flake-parts.lib.mkFlake { inherit inputs; } {
      # systems that his flake can be used on
      systems = [ "aarch64-darwin" "x86_64-linux" "x86_64-darwin" ];

      # for each system...
      perSystem = { config, pkgs, system, ... }:
        let
          # include Rust overlay in nixpkgs
          overlays = [ (import rust-overlay) ];
          pkgs = import nixpkgs {
            inherit system overlays;
          };

          rustVersion = "1.78.0";

          # define Rust toolchain version and targets to be used in this flake
          rust = (pkgs.rust-bin.stable.${rustVersion}.minimal.override
            {
              targets = [ "wasm32-unknown-unknown" ];
            });

          # instruct crane to use Rust toolchain specified above
          craneLib = (crane.mkLib pkgs).overrideToolchain rust;

          # define how to build Holochain binaries
          holochain =
            let
              # Crane filters out all non-cargo related files. Define include filter with files needed for build.
              nonCargoBuildFiles = path: _type: builtins.match ".*(json|sql|wasm.gz)$" path != null;
              includeFilesFilter = path: type:
                (craneLib.filterCargoSources path type) || (nonCargoBuildFiles path type);

              # Crane doesn't know which version to select from a workspace, so we tell it where to look
              crateInfo = craneLib.crateNameFromCargoToml { cargoToml = inputs.holochain + "/crates/holochain/Cargo.toml"; };
            in
            craneLib.buildPackage {
              pname = "holochain";
              version = crateInfo.version;
              # Use Holochain sources as defined in input dependencies and include only those files defined in the
              # filter previously.
              src = pkgs.lib.cleanSourceWith {
                src = inputs.holochain;
                filter = includeFilesFilter;
              };
              # additional packages needed for build
              buildInputs = [
                pkgs.go
                pkgs.perl
              ];
              # do not check built package as it either builds successfully or not
              doCheck = false;
            };

          # define how to build Lair keystore binary
          lair-keystore =
            let
              # Crane filters out all non-cargo related files. Define include filter with files needed for build.
              nonCargoBuildFiles = path: _type: builtins.match ".*(sql|md)$" path != null;
              includeFilesFilter = path: type:
                (craneLib.filterCargoSources path type) || (nonCargoBuildFiles path type);

              # Crane doesn't know which version to select from a workspace, so we tell it where to look
              crateInfo = craneLib.crateNameFromCargoToml { cargoToml = inputs.lair-keystore + "/crates/lair_keystore/Cargo.toml"; };
            in
            craneLib.buildPackage {
              pname = "lair-keystore";
              version = crateInfo.version;
              # only build lair-keystore binary
              cargoExtraArgs = "--bin lair-keystore";
              # Use Lair keystore sources as defined in input dependencies and include only those files defined in the
              # filter previously.
              src = pkgs.lib.cleanSourceWith {
                src = inputs.lair-keystore;
                filter = includeFilesFilter;
              };
              # additional packages needed for build
              # perl needed for openssl on all platforms
              buildInputs = [ pkgs.perl ]
                ++ (pkgs.lib.optionals pkgs.stdenv.isDarwin [
                # additional packages needed for darwin platforms
                pkgs.libiconv
                pkgs.darwin.apple_sdk.frameworks.Security
                # additional packages needed for darwin platforms on x86_64
                pkgs.darwin.apple_sdk_11_0.frameworks.CoreFoundation
              ]);
              # do not check built package as it either builds successfully or not
              doCheck = false;
            };

          # define how to build hc-launch binary
          hc-launch =
            let
              # Crane filters out all non-cargo related files. Define include filter with files needed for build.
              nonCargoBuildFiles = path: _type: builtins.match ".*(js|json|png)$" path != null;
              includeFilesFilter = path: type:
                (craneLib.filterCargoSources path type) || (nonCargoBuildFiles path type);

              # Crane doesn't know which version to select from a workspace, so we tell it where to look
              crateInfo = craneLib.crateNameFromCargoToml { cargoToml = inputs.hc-launch + "/crates/hc_launch/src-tauri/Cargo.toml"; };

              # Use consistent version of Apple SDK throughout. Without this, building on x86_64-darwin fails.
              # See below.
              apple_sdk =
                if system == "x86_64-darwin"
                then pkgs.darwin.apple_sdk_10_12
                else pkgs.darwin.apple_sdk_11_0;

              commonArgs = {
                pname = "hc-launch";
                version = crateInfo.version;
                # Use hc-launch sources as defined in input dependencies and include only those files defined in the
                # filter previously.
                src = pkgs.lib.cleanSourceWith {
                  src = inputs.hc-launch;
                  filter = includeFilesFilter;
                };
                # Only build hc-launch command
                cargoExtraArgs = "--bin hc-launch";

                # commands required at build time
                nativeBuildInputs = (
                  if pkgs.stdenv.isLinux then [ pkgs.pkg-config ]
                  else [ ]
                );

                # build inputs required for linking to execute at runtime
                buildInputs = [
                  pkgs.perl
                ]
                ++ (pkgs.lib.optionals pkgs.stdenv.isLinux
                  [
                    pkgs.glib
                    pkgs.go
                    pkgs.webkitgtk.dev
                  ])
                ++ pkgs.lib.optionals pkgs.stdenv.isDarwin
                  [
                    apple_sdk.frameworks.AppKit
                    apple_sdk.frameworks.WebKit

                    (if pkgs.system == "x86_64-darwin" then
                      pkgs.darwin.apple_sdk_11_0.stdenv.mkDerivation
                        {
                          name = "go";
                          nativeBuildInputs = with pkgs; [
                            makeBinaryWrapper
                            go
                          ];
                          dontBuild = true;
                          dontUnpack = true;
                          installPhase = ''
                            makeWrapper ${pkgs.go}/bin/go $out/bin/go
                          '';
                        }
                    else pkgs.go)
                  ];

                # do not check built package as it either builds successfully or not
                doCheck = false;
              };

              # derivation building all dependencies
              deps = craneLib.buildDepsOnly commonArgs;
            in
            # derivation with the main crates
            craneLib.buildPackage
              (commonArgs // {
                cargoArtifacts = deps;

                # Override stdenv Apple SDK packages. It's unclear why this is needed, but building on x86_64-darwin
                # fails without it.
                # https://discourse.nixos.org/t/need-help-from-darwin-users-syntax-errors-in-library-frameworks-foundation-framework-headers/30467/3
                stdenv =
                  if pkgs.stdenv.isDarwin then
                    pkgs.overrideSDK pkgs.stdenv "11.0"
                  else
                    pkgs.stdenv;
              });

          hc-scaffold =
            craneLib.buildPackage {
              pname = "hc-scaffold";
              src = craneLib.cleanCargoSource inputs.hc-scaffold;

              doCheck = false;

              buildInputs = [
                pkgs.go
                pkgs.perl
              ];
            };
        in
        {
          # Configure a formatter so that `nix fmt` can be used to format this file.
          formatter = pkgs.nixpkgs-fmt;

          packages = {
            inherit holochain;
            inherit lair-keystore;
            inherit hc-launch;
            inherit hc-scaffold;
            inherit rust;
          };

          # Define runnable applications for use with `nix run`.
          # These can be used like `nix run "github:holochain/holonix#hc-scaffold" -- --version`.
          # https://flake.parts/options/flake-parts.html?highlight=perSystem.apps#opt-perSystem.apps
          apps = {
            holochain.program = "${holochain}/bin/holochain";
            hc.program = "${holochain}/bin/hc";
            hc-run-local-services.program = "${holochain}/bin/hc-run-local-services";
            hc-sandbox.program = "${holochain}/bin/hc-sandbox";
            hcterm.program = "${holochain}/bin/hcterm";
            lair-keystore.program = "${lair-keystore}/bin/lair-keystore";
            hc-launch.program = "${hc-launch}/bin/hc-launch";
            hc-scaffold.program = "${hc-scaffold}/bin/hc-scaffold";
          };

          devShells = {
            default = pkgs.mkShell {
              packages = [
                holochain
                lair-keystore
                hc-launch
                hc-scaffold
                rust
              ];
            };
          };
        };
    };
}
