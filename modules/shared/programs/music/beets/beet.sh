export PATH=@FFMPEG@/bin:$PATH
exec @PACKAGE@/bin/beet -c @CONFIG@ "$@"
