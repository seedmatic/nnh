# replaceVars' @name@ substitution, at evaluation time: the text of `file` with each `@name@` replaced by its
# value, with replaceVars' two guarantees (every name is there to replace, none is left). Reading the output
# of replaceVars with readFile is import-from-derivation: evaluating it builds the script and everything its
# values name. The values keep their string context, so the text still depends on what they name.
#
# One name after the other, in sorted order, each in the text so far: replaceVars' `substitute
# --replace-fail` does the same, so a value may carry a name replaced after it (an inlined library's own
# @name@).
lib: file: vars:
let
  step =
    text: n:
    assert lib.assertMsg (lib.hasInfix "@${n}@" text) "${toString file}: no @${n}@ to replace";
    builtins.replaceStrings [ "@${n}@" ] [ (toString vars.${n}) ] text;
  text = builtins.foldl' step (builtins.readFile file) (builtins.attrNames vars);
  left = lib.concatMap lib.toList (
    builtins.filter builtins.isList (builtins.split "(@[a-zA-Z_][0-9A-Za-z_'-]*@)" text)
  );
in
assert lib.assertMsg (
  left == [ ]
) "${toString file}: ${lib.concatStringsSep ", " left} left unreplaced";
text
