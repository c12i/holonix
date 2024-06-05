{
  description = "Flake for Holochain app development";

  inputs = {
    holonix.url = "github:holochain/holonix/main";

    nixpkgs.follows = "holonix/nixpkgs";
    flake-parts.follows = "holonix/flake-parts";
  };

  outputs = inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = builtins.attrNames inputs.holonix.devShells;
      perSystem =
        { inputs'
        , pkgs
        , ...
        }:
        {
          formatter = pkgs.nixpkgs-fmt;

          packages = with pkgs; [
            nodejs_20 # For UI development
            binaryen # For WASM optimisation
            # Add any other packages you need here
          ];

          devShells.default = pkgs.mkShell {
            inputsFrom = [ inputs'.holonix.devShells ];
          };
        };
    };
}
