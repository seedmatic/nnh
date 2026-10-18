# No nix file of this repo reads a derivation's output with builtins.readFile: that is import-from-derivation,
# and evaluating the flake would build it (nix/replace-vars-text.nix replaces the replaceVars case). The
# pattern is matched across lines, as nixfmt splits the call; it must catch a sample of it, and leave the
# replacement alone.
{ pkgs, src }:
let
  inherit (pkgs) lib;
  nixFiles = lib.fileset.toSource {
    root = src;
    fileset = lib.fileset.fileFilter (f: f.hasExt "nix") src;
  };
  builders = "replaceVars|replaceVarsWith|substituteAll|substitute|runCommand\\w*|writeText\\w*|writeShellScript\\w*|writeScript\\w*";
  # Spelled in pieces, so this file does not match its own pattern.
  caught = pkgs.writeText "caught.nix" (
    "{ x = builtins.read" + "File (\n  pkgs.replace" + "Vars ./x.sh { };\n}\n"
  );
  spared = pkgs.writeText "spared.nix" ''
    { x = import ./nix/replace-vars-text.nix lib ./x.sh { }; y = builtins.readFile ./x.sh; }
  '';
in
pkgs.runCommand "no-ifd-readfile" { nativeBuildInputs = [ pkgs.gnugrep ]; } ''
  pattern='readFile\s*\(\s*(?:[\w.]+\.)?(?:${builders})\b'
  grep -qPz "$pattern" ${caught} || { echo "FAIL the pattern misses a readFile of replaceVars"; exit 1; }
  ! grep -qPz "$pattern" ${spared} || { echo "FAIL the pattern catches the replacement"; exit 1; }
  if found=$(cd ${nixFiles} && grep -rlPz "$pattern" .); then
    echo "readFile of a derivation (import-from-derivation) in:"; printf '  %s\n' $found
    exit 1
  fi
  touch $out
''
