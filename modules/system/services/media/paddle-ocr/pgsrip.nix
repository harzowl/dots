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

  meta = with lib; {
    description = "Rip, convert and OCR PGS subtitles";
    homepage = "https://github.com/ratoaq2/pgsrip";
    license = licenses.mit;
    mainProgram = "pgsrip";
  };
}
