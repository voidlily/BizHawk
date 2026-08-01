{
  lib,
  callPackage,
  callPackages,
  # infrastructure
  dpkg,
  fetchzip,
  makeDesktopItem,
  runCommand,
  # source
  hawkSourceInfoDevBuild ?
    let # called "dev build", but you could pass whatever branch and commit you want here
      version = "2.11.2-local"; # used in default value of `BIZHAWK_DATA_HOME`, which distinguishes parallel installs' config and other data
    in
    {
      inherit version;
      src = builtins.path {
        path = ./.;
        name = "BizHawk-${version}";
      }; # source derivation; did have filter here for speed, but it wasn't faster and it wasn't correct and it couldn't be made correct and I'm mad
    },
  # rundeps
  coreutils,
  kate,
  mono,
  omnisharp-roslyn,
  # historical
  fetchFromGitHub,
  fetchFromGitLab,
  mkNugetDeps,
  dotnet-sdk_5,
  dotnet-sdk_6,
  dotnet-sdk_8,
  # other parameters
  buildConfig ? "Release", # "Debug"/"Release"
  debugPInvokes ? false, # forwarded to Dist/launch-scripts.nix
  debugDotnetHostCrashes ? false, # forwarded to Dist/launch-scripts.nix
  doCheck ? true, # runs `Dist/BuildTest${buildConfig}.sh`
  extraDefines ? "", # added to `<DefineConstants/>`, so ';'-separated
  extraDotnetBuildFlags ? "", # currently passed to EVERY `dotnet build` and `dotnet test` invocation (and does not replace the flags for parallel compilation added by default)
  forNixOS ? true,
  initConfig ? { }, # forwarded to Dist/launch-scripts.nix (see docs there)
  profileManagedCalls ? false, # forwarded to Dist/launch-scripts.nix
}:
let
  isVersionAtLeast = lib.flip lib.versionAtLeast; # I stand by this being the more useful param order w.r.t. currying
  replaceDotWithUnderscore = s: lib.replaceStrings [ "." ] [ "_" ] s;
  /**
    you can't actually make hard links in the sandbox, so this just copies, and we'll rely on Nix' automatic deduping
  */
  hardLinkJoin =
    {
      name,
      paths,
      preferLocalBuild ? true,
      allowSubstitutes ? false,
      __contentAddressed ? false,
    }:
    runCommand name
      {
        inherit
          __contentAddressed
          allowSubstitutes
          paths
          preferLocalBuild
          ;
        passAsFile = [ "paths" ];
      }
      ''
        			mkdir -p $out
        			for d in $(cat $pathsPath); do
        				cd "$d"
        				find . -type d -exec mkdir -p "$out/{}" \;
        				for f in $(find . -type f); do cp -T "$(realpath "$f")" "$out/$f"; done
        			done
        		'';
  inherit
    (import Dist/historical.nix {
      inherit
        lib
        isVersionAtLeast
        replaceDotWithUnderscore
        fetchFromGitHub
        fetchFromGitLab
        mkNugetDeps
        dotnet-sdk_5
        dotnet-sdk_6
        dotnet-sdk_8
        ;
    })
    depsForHistoricalRelease
    populateHawkSourceInfo
    releaseArtifactInfos
    releaseFrags
    releaseTagSourceInfos
    ;
  launchScriptsFor =
    bizhawkAssemblies: isManualLocalBuild:
    callPackages Dist/launch-scripts.nix {
      inherit

        bizhawkAssemblies
        debugPInvokes
        debugDotnetHostCrashes
        initConfig
        isManualLocalBuild
        profileManagedCalls
        ;
      mkfifo = coreutils;
      mktemp = coreutils;
    };
  pp = callPackages Dist/packages.nix {
    inherit

      populateHawkSourceInfo
      replaceDotWithUnderscore
      hardLinkJoin
      launchScriptsFor
      makeDesktopItem
      releaseTagSourceInfos
      buildConfig
      doCheck
      extraDefines
      extraDotnetBuildFlags
      libretroCores
      ;
    mono = lib.recursiveUpdate { meta.mainProgram = "mono"; } mono;
    monoBasic = fetchzip {
      url = "https://download.mono-project.com/repo/debian/pool/main/m/mono-basic/libmono-microsoft-visualbasic10.0-cil_4.7-0xamarin3+debian9b1_all.deb";
      nativeBuildInputs = [ dpkg ];
      hash = "sha512-bPXbsVrViHAJz6PWuryo9HA6Nlv0bNqgc72pNKM/MUQM7JTUcfM0VDUzkz8vzXSqp/nt2LlAOIqIsS5D5iBIvQ==";
      # tried and failed building from source, following https://aur.archlinux.org/cgit/aur.git/tree/PKGBUILD?h=mono-basic
    };
  };
  emuhawk-local = pp.buildEmuHawkInstallableFor {
    inherit forNixOS;
    hawkSourceInfo = hawkSourceInfoDevBuild;
  };
  fillTargetOSDifferences =
    hawkSourceInfo: lib.optionalAttrs forNixOS { needsLibGLVND = true; } // hawkSourceInfo; # don't like this, but the alternative is including `forNixOS` in `hawkSourceInfo` directly
  asmsFromReleaseArtifacts = lib.mapAttrs (
    _: a: pp.splitReleaseArtifact (a // { hawkSourceInfo = fillTargetOSDifferences a.hawkSourceInfo; })
  ) releaseArtifactInfos;
  # the asms for from-CWD and latest release from-source are exposed below as `bizhawkAssemblies` and `bizhawkAssemblies-latest`, respectively
  # apart from that, no `asmsFromSource`, since if you're only after the assets you might as well use the release artifact
  releasesEmuHawkInstallables = lib.pipe releaseFrags [
    (builtins.map (versionFrag: [
      ({
        name = "emuhawk-${versionFrag}";
        value = pp.buildEmuHawkInstallableFor {
          inherit forNixOS;
          hawkSourceInfo = releaseTagSourceInfos."info-${versionFrag}";
        };
      })
      ({
        name = "emuhawk-${versionFrag}-bin";
        value = pp.buildEmuHawkInstallableFor {
          inherit forNixOS;
          bizhawkAssemblies = asmsFromReleaseArtifacts."bizhawkAssemblies-${versionFrag}-bin";
        };
      })
    ]))
    lib.concatLists
    lib.listToAttrs
    (lib.filterAttrs (
      name: value: lib.hasSuffix "-bin" name || isVersionAtLeast "2.6" value.hawkSourceInfo.version
    ))
  ];
  latestVersionFrag = lib.head releaseFrags;
  combined =
    pp
    // asmsFromReleaseArtifacts
    // releasesEmuHawkInstallables
    // {
      inherit depsForHistoricalRelease populateHawkSourceInfo releaseTagSourceInfos;
      inherit (emuhawk-local.assemblies) libretroCores;
      bizhawkAssemblies = pp.buildAssembliesFor (fillTargetOSDifferences hawkSourceInfoDevBuild);
      "bizhawkAssemblies-${latestVersionFrag}" = pp.buildAssembliesFor (
        fillTargetOSDifferences releaseTagSourceInfos."info-${latestVersionFrag}"
      );
      discohawk = pp.buildDiscoHawkInstallableFor {
        inherit forNixOS;
        hawkSourceInfo = hawkSourceInfoDevBuild;
      };
      "discohawk-${latestVersionFrag}" = pp.buildDiscoHawkInstallableFor {
        inherit forNixOS;
        hawkSourceInfo = releaseTagSourceInfos."info-${latestVersionFrag}";
      };
      "discohawk-${latestVersionFrag}-bin" = pp.buildDiscoHawkInstallableFor {
        inherit forNixOS;
        bizhawkAssemblies = asmsFromReleaseArtifacts."bizhawkAssemblies-${latestVersionFrag}-bin";
      };
      emuhawk = emuhawk-local;
      IDEs = {
        kate = [
          kate
          omnisharp-roslyn
        ];
      };
      launchScriptsForLocalBuild = launchScriptsFor emuhawk-local.assemblies true;
    };
  libretroCores = callPackage Dist/packages-libretro.nix { };
in
combined
// lib.listToAttrs (
  lib.concatLists (
    builtins.map
      (f: [
        {
          name = f "latest-bin";
          value = combined.${f "${latestVersionFrag}-bin"};
        }
        {
          name = f "latest";
          value = combined.${f latestVersionFrag};
        }
      ])
      [
        (s: "bizhawkAssemblies-${s}")
        (s: "emuhawk-${s}")
        (s: "discohawk-${s}")
      ]
  )
)
