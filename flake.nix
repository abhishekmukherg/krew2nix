{
  description =
    "Makes kubectl plug-ins from the Krew repository accessible to Nix";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  inputs.krew-index = {
    url = "github:kubernetes-sigs/krew-index";
    flake = false;
  };
  outputs = { self, nixpkgs, flake-utils, krew-index }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        krewPlugins = pkgs.callPackage ./krew-plugins.nix { };
        kubectl = pkgs.callPackage ./kubectl.nix { };
      in
      { packages = krewPlugins // { inherit kubectl krew-index; }; });
}
