# The Krew repository lists available plugin artifacts in YAML files. This
# module consumes the Krew repository to automatically create a set of Nix
# derivations. Most plugins are statically compiled binaries, but some are shell
# scripts or may have external dependencies (which Krew plugin definitions do
# not express), so YMMV.
{ autoPatchelfHook
, buildPackages
, fetchFromGitHub
, go
, lib
, stdenv
, targetPlatform
, unzip
, krew-index
}:

let
  inherit (builtins) filter length elem any replaceStrings;
  inherit (lib)
    head nameValuePair assertMsg filesystem id listToAttrs concatStringsSep
    licenses;
  jsonFilenameFromYaml = yamlFile: let
    basename = lib.lists.last ( lib.strings.splitString "/" yamlFile );
  in "${lib.strings.removeSuffix ".yaml" basename}.json";
  pluginDerivations = listToAttrs (map
    (yamlFile:

      let
        pluginDefinition = builtins.fromJSON(builtins.readFile "${krewIndexAsJson}/plugins/${jsonFilenameFromYaml yamlFile}");
        pluginName = pluginDefinition.metadata.name;
      in
      nameValuePair pluginName (mkPlugin pluginDefinition))
    allPluginDefinitions);
  mkPlugin = pluginDefinition:
    let
      pluginName = pluginDefinition.metadata.name;
      matchingPlatforms =
        filter isPlatformMatch pluginDefinition.spec.platforms;
      selectedPlatform = assert (assertMsg (length matchingPlatforms > 0)
        "target platform is not supported by plugin ${pluginName}");
        head matchingPlatforms;
      # Plugin files to be installed are sometimes listed as from/to-pairs (copy
      # from foo to bar). The “from” value may be preceeded by a slash, so we
      # need to force a relative path.
      copyPluginFilesCommands =
        if selectedPlatform ? files then
          map (fromTo: "cp -a ./${fromTo.from} $out/lib/${fromTo.to}")
            selectedPlatform.files
        else
          [ "cp -a * $out/lib" ];
      # When plugin definitions contain dashes, such as “foo-bar”, Krew
      # implicitly transforms dashes into underscores. This ensures that the
      # plugin can be invoked as “kubectl foo-bar”, instead of “kubectl foo
      # bar”.
      pluginBinaryName = "kubectl-${replaceStrings [ "-" ] [ "_" ] pluginName}";
    in
    stdenv.mkDerivation {
      pname = "kubectl-krew-plugin-${pluginName}";
      version = pluginDefinition.spec.version;
      src = builtins.fetchurl {
        url = selectedPlatform.uri;
        sha256 = selectedPlatform.sha256;
      };
      sourceRoot = ".";
      dontBuild = true;
      nativeBuildInputs = [ unzip ] ++ lib.optionals (stdenv.isLinux) [ autoPatchelfHook ];
      installPhase = ''
        runHook preInstall
        mkdir -p $out/{bin,lib}
        ${concatStringsSep "\n" copyPluginFilesCommands}
        ln -s $out/lib/${selectedPlatform.bin} $out/bin/${pluginBinaryName}
        runHook postInstall
      '';
      meta = {
        description = pluginDefinition.spec.description or "Plugin for kubectl";
        platforms =
          if length matchingPlatforms > 0 then
            [ targetPlatform.system ]
          else
            [ ];
      };
    };
  krewIndexAsJson = buildPackages.runCommandLocal "read-yaml" {} ''
    mkdir -p $out/plugins
    for file in ${krew-index}/plugins/*.yaml; do
      ${buildPackages.remarshal}/bin/remarshal -if yaml -i $file -of json -o $out/plugins/$(basename $file .yaml).json
    done
  '';
  allPluginDefinitions = filesystem.listFilesRecursive "${krew-index}/plugins";
  # Krew is using Golang terminology when listing plugin artifacts by platform.
  targetOs = go.GOOS;
  targetArch = go.GOARCH;
  # Krew plugin definitions list artifact URLs in conjunction with selectors to
  # determine plugin artifacts to install.
  isPlatformMatch = platform:
    if platform.selector ? matchExpressions then
      isPlatformMatchByExpressions platform
    else
      (if platform.selector ? matchLabels then
        isPlatformMatchByLabels platform
      else
        abort "unhandled switch case");
  isPlatformMatchByExpressions = platform:
    let
      matchesExpression = expression:
        assert expression.operator == "In";
        assert expression.key == "os";
        elem targetOs expression.values;
      matchResults = map matchesExpression platform.selector.matchExpressions;
    in
    any id matchResults;
  isPlatformMatchByLabels = platform:
    let
      matchesOs = platform.selector.matchLabels.os or targetOs == targetOs;
      matchesArch = platform.selector.matchLabels.arch or targetArch
        == targetArch;
    in
    matchesOs && matchesArch;
in
pluginDerivations
