# nnh holds no secret (a843ca0 removed its .secrets, its sops rule and its diff driver): no .sops.yaml, and no file a
# sops envelope encrypts. A sops file is recognised by its envelope (a top-level sops key holding the mac, in YAML
# or in JSON), not by its name or by a mention of sops. Two mutants must be refused: a .sops.yaml, and an encrypted
# file.
{ pkgs, src }:
let
  inherit (pkgs) lib;
  files = lib.fileset.toSource {
    root = src;
    fileset = lib.fileset.difference src (lib.fileset.maybeMissing (src + "/.git"));
  };
  # Spelled in pieces, so this file does not match its own pattern.
  envelope = pkgs.writeText "encrypted.yaml" (
    "token: ENC[AES256_GCM,data:x,iv:y,tag:z,type:str]\n"
    + "so"
    + "ps:\n    mac: ENC[AES256_GCM,data:x,iv:y,tag:z,type:str]\n    version: 3.9.0\n"
  );
in
pkgs.runCommand "no-sops-files" { nativeBuildInputs = [ pkgs.gnugrep pkgs.findutils ]; } ''
  # grep finding nothing exits 1, which stdenv's errexit would take for a failure: no match is the passing case.
  holds_secret() { # <tree>: prints what makes it hold one
    find "$1" -name .sops.yaml -printf '%P is a sops creation rule\n'
    { grep -rlZ -E '^sops:[[:space:]]*$' "$1" || true; } | xargs -0 -r grep -lE '^[[:space:]]+mac:' | sed "s|^$1/||; s|$| is sops-encrypted|" || true
    { grep -rlE '"sops":[[:space:]]*\{' "$1" || true; } | sed "s|^$1/||; s|$| is sops-encrypted|"
  }
  found=$(holds_secret ${files})
  [ -z "$found" ] || { echo "nnh holds a secret again:"; printf '  %s\n' "$found"; exit 1; }
  echo "ok   no .sops.yaml, no sops-encrypted file"
  for m in sops-yaml encrypted; do
    rm -rf mutant && cp -r ${files} mutant && chmod -R u+w mutant
    case $m in
      sops-yaml) printf 'creation_rules: []\n' >mutant/.sops.yaml ;;
      encrypted) cp ${envelope} mutant/secret.yaml ;;
    esac
    [ -n "$(holds_secret mutant)" ] || { echo "FAIL mutant '$m' passed"; exit 1; }
    echo "ok   mutant '$m' refused"
  done
  touch $out
''
