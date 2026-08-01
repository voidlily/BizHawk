{
  description = "BizHawk is a multi-system emulator written in C#. BizHawk provides nice features for casual gamers such as full screen, and joypad support in addition to full rerecording and debugging tools for all system cores.";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    nixpkgs-26_05.url = "github:nixos/nixpkgs?ref=nixos-26.05";
    # .NET 10 backported to 24.05, since that was the last release before ebd3b37e6, see https://github.com/NixOS/nixpkgs/pull/327651#issuecomment-3499977198
    nixpkgs-24_05.url = "github:YoshiRulz/nixpkgs?ref=a9302067440792f6137e4e96f3bfcbb1ed086eb2";
    # commit immediately before .NET 5 was removed
    nixpkgs-22_11-with-dotnet-5.url = "github:nixos/nixpkgs?ref=a8f575995434695a10b574d35ca51b0f26ae9049";
    nixgl.url = "github:nix-community/nixgl?ref=489d6b095ab9d289fe11af0219a9ff00fe87c7c5";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    systems.url = "github:nix-systems/default";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-22_11-with-dotnet-5,
      nixgl,
      systems,
      treefmt-nix,
      ...
    }:

    let
      system = "x86_64-linux";
      eachSystem = f: nixpkgs.lib.genAttrs (import systems) (system: f nixpkgs.legacyPackages.${system});
      pkgs = import nixpkgs {
        inherit system;
        config.permittedInsecurePackages = [
          "dotnet-sdk-6.0.428"
          "dotnet-runtime-6.0.36"
        ];
      };
      pkgs-22_11 = import nixpkgs-22_11-with-dotnet-5 { inherit system; };
      callPackageArgs = pkgs // {
        # lua in nixpkgs defaults to 5.2, we need 5.4
        lua = pkgs.lua5_4;
        nixGL = nixgl.packages.default;
        dotnet-sdk_5 = pkgs-22_11.dotnet-sdk_5;
        kate = pkgs.kate.overrideAttrs (oldAttrs: {
          patches = (oldAttrs.patches or [ ]) ++ [
            (pkgs.fetchpatch {
              url = "https://invent.kde.org/utilities/kate/-/commit/9ddf4f0c9eb3c26a0ab33c862d2b161bcbdc6a6e.patch"; # Fix name of OmniSharp LSP binary
              hash = "sha256-a2KqoxuuVhfAQUJA3/yEQb1QCoa1JCvLz7BZZnSLnzI=";
            })
          ];
        });
      };
      callPackage = pkgs.lib.callPackageWith callPackageArgs;
      callPackages = pkgs.lib.callPackagesWith callPackageArgs;
      treefmtEval = eachSystem (
        pkgs:
        treefmt-nix.lib.evalModule pkgs {
          projectRootFile = "flake.nix";
          programs.nixfmt.enable = true;
        }
      );
    in
    {
      packages.x86_64-linux = (
        # default.nix also outputs things that are not derivations, so we remove
        # those to make sure the flake output is valid
        # https://github.com/TASEmulators/BizHawk/blob/master/Dist/nix_expr_usage_docs.md
        removeAttrs
          (callPackages ./default.nix {
            inherit callPackage callPackages;
          })
          [
            "buildAssembliesFor"
            "buildDiscoHawkInstallableFor"
            "buildEmuHawkInstallableFor"
            "buildExtraManagedDepsFor"
            "buildUnmanagedDepsFor"
            "depsForHistoricalRelease"
            "IDEs"
            "launchScriptsForLocalBuild"
            "libretroCores"
            "populateHawkSourceInfo"
            "releaseTagSourceInfos"
            "splitReleaseArtifact"
          ]
        // {
          default = self.packages.x86_64-linux.emuhawk;
        }
      );

      devShells.x86_64-linux.default = callPackage ./shell.nix {
        inherit callPackage callPackages;
      };

      # for `nix fmt`
      formatter = eachSystem (pkgs: treefmtEval.${pkgs.system}.config.build.wrapper);
      # for `nix flake check`
      checks = eachSystem (pkgs: {
        formatting = treefmtEval.${pkgs.system}.config.build.check self;
      });
    };
}
