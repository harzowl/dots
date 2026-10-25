{
  lib,
  python3Packages,
  fetchPypi,
  tesseract,
}:
python3Packages.buildPythonPackage rec {
  pname = "pgsrip";
  version = "0.3.0";
  format = "pyproject";

  src = fetchPypi {
    inherit pname version;
    hash = "sha256-eBgd5P63hDx+mNR/0c1+mivcv9U7o/YwLxkImm7CCMc=";
  };

  build-system = [ python3Packages.hatchling ];

  # The OCR server only reads PGS display sets. The package __init__ imports the
  # CLI/engine layer, whose openai engine needs click >= 8.5 (nixpkgs ships 8.3).
  postPatch = ''
    sed -i '/^from \.api import/d' pgsrip/__init__.py
  '';

  propagatedBuildInputs = with python3Packages; [
    appdirs
    babelfish
    cleanit
    click
    numpy
    opencv4
    pysrt
    pytesseract
    pyyaml
    setuptools
    trakit
  ];

  buildInputs = [ tesseract ];

  doCheck = false;
  # The wheel's metadata bounds are newer than nixpkgs (cleanit 0.5.1 vs 0.4.9,
  # click 8.5.0 vs 8.3.1) and it names opencv-python where nixpkgs provides
  # opencv4. The OCR server only uses pgsrip.formats.pgs, so skip the metadata check.
  dontCheckRuntimeDeps = true;

  meta = with lib; {
    description = "Rip, convert and OCR PGS subtitles";
    homepage = "https://github.com/ratoaq2/pgsrip";
    license = licenses.mit;
    mainProgram = "pgsrip";
  };
}
