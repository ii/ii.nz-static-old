{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
    harbor = {
      url = "github:matsuyoshi30/harbor";
      flake = false;
    };
  };
  outputs = { self, nixpkgs, flake-utils, harbor }:
    flake-utils.lib.eachDefaultSystem (system:
      let pkgs = nixpkgs.legacyPackages.${system};
          blog = pkgs.stdenv.mkDerivation {
            name = "blog";
            src = builtins.filterSource
              (path: type: !(type == ''directory'' &&
                             (baseNameOf path == ''themes'' ||
                              baseNameOf path == ''public'')))
              ./.;
            buildPhase = ''
              mkdir -p themes
              ln -s ${harbor} themes/harbor
              ${pkgs.hugo}/bin/hugo --minify
            '';
            installPhase = ''
              cp -r public $out
            '';
            meta = with pkgs.lib; {
              description = ''the ii.nz blog'';
              platforms = platforms.all;
            };
          };
      in {
        packages =  {
          blog = blog;
          default = blog;
        };
        devShell = pkgs.mkShell {
          buildInputs = with pkgs; [ hello cowsay hugo];
          shellHook = ''
            mkdir -p themes
            ln -sf ${harbor} themes/harbor
          '';
        };
      });
}
