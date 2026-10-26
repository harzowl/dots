{
  lib,
  fetchFromGitHub,
  fetchPypi,
  stdenv,
  python3,
  python3Packages,
}:
let
  slskd-api = python3Packages.buildPythonPackage rec {
    pname = "slskd-api";
    version = "0.1.5";
    format = "other";

    src = fetchPypi {
      inherit pname version;
      hash = "sha256-LmWP7bnK5IVid255qS2NGOmyKzGpUl3xsO5vi5uJI88=";
    };

    propagatedBuildInputs = [ python3Packages.requests ];

    dontBuild = true;
    doCheck = false;

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/${python3.sitePackages}"
      cp -r slskd_api "$out/${python3.sitePackages}/"
      runHook postInstall
    '';

    meta = {
      description = "Python client for the slskd API";
      license = lib.licenses.agpl3Only;
      platforms = lib.platforms.linux;
    };
  };

  python = python3.withPackages (ps: [
    ps.music-tag
    ps.pyarr
    ps.flask
    ps.waitress
    slskd-api
  ]);
in
stdenv.mkDerivation rec {
  pname = "soularr";
  version = "unstable-2026-10-06";

  src = fetchFromGitHub {
    owner = "mrusse";
    repo = "soularr";
    rev = "2037399aa57433f9032bbae09833439830d2b409";
    hash = "sha256-a/HufH1y5QOX0jJolz8oVXZvOlCzg41ab+S35ZsWhWk=";
  };

  patches = [
    ./0001-resolve-nested-slskd-layout.patch
    ./0003-per-source-page.patch
  ];

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/share/soularr" "$out/bin"
    cp -r soularr.py webui resources "$out/share/soularr/"
    cat > "$out/bin/soularr" <<EOF
    #!${python.interpreter}
    import runpy
    import sys

    script = "$out/share/soularr/soularr.py"
    sys.argv[0] = script
    runpy.run_path(script, run_name="__main__")
    EOF
    chmod +x "$out/bin/soularr"
    runHook postInstall
  '';

  meta = {
    description = "Lidarr and slskd bridge that downloads wanted albums over Soulseek";
    homepage = "https://github.com/mrusse/soularr";
    license = lib.licenses.gpl3Only;
    mainProgram = "soularr";
    platforms = lib.platforms.linux;
  };
}
