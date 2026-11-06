#!/bin/zsh
# The plugin against in-process MLXServeEngine: seeded jobs called on the signed bundle the way Gaea calls them
# (gaea-plugin-check: launch under the launch requirement, configure, prepare, run) and through voxcpm2-inproc with the
# lane configuration, requests and seeding the worker uses. Each pair must be byte for byte the same WAV.
#
#   scripts/golden.sh <out-dir>     (after scripts/build-plugin.sh)
#
# Cases: the default voice, happy with a pause, a delivery description, Chinese, a clone of scripts/fixtures/ref-en.wav
# and its continuation clone with the clip's words, two designed samples (seed 7 and 8), and the first one cloned back
# with its text.
set -uo pipefail
ROOT=${0:A:h:h}
cd $ROOT
OUT=${1:?out dir}; mkdir -p $OUT
B=$ROOT/dist/voxcpm2.gaeaplugin
REF=$ROOT/scripts/fixtures/ref-en.wav
REFTEXT='The morning train was late again, so I walked along the river and watched the boats come in.'
MODELS=${CHECK_MODELS_ROOT:-/Volumes/DEV_VOL1/Models/Models}
SWIFTPM=(-c release --build-system swiftbuild)
xcrun swift build $SWIFTPM --product voxcpm2-inproc > /dev/null && xcrun swift build -c release --product gaea-plugin-check > /dev/null
INPROC=$(xcrun swift build $SWIFTPM --show-bin-path)/voxcpm2-inproc; CHECK=$(xcrun swift build -c release --show-bin-path)/gaea-plugin-check
LOG=$OUT/golden.log; : > $LOG
pass=0; fail=0
say() { print -r -- "$*" | tee -a $LOG }
say "# VoxCPM2 golden check $(date -u +%FT%TZ): $(python3 -c "import json; m=json.load(open('$B/Contents/Resources/manifest.json')); print(m['id'], m['version'])")"
same() { # name, gpp wav, inproc wav
  local a=$(shasum -a 256 $2 2>/dev/null | cut -c1-16) b=$(shasum -a 256 $3 2>/dev/null | cut -c1-16)
  if [[ -n $a && $a == $b ]]; then pass=$((pass+1)); say "PASS  $1: byte-identical, sha256 $a…"
  else fail=$((fail+1)); say "FAIL  $1: differs ($a… / $b…)"; fi
}
outputs() { grep -o '"path":"[^"]*"' $1 | sed 's/"path":"//; s/"$//; s/\\\//\//g' }
gpp() { # name, operation, seed, params json, --text/--input args… → the job's outputs copied to <name>-gpp-<i>.wav
  local name=$1 op=$2 seed=$3 params=$4; shift 4
  $CHECK $B --operation $op --model voxcpm2 --lane bf16 --params $params --seed $seed "$@" \
    --models-root "$MODELS" --budget 64000000000 --timeout 900 --session $OUT/$name.gpp > $OUT/$name-gpp.log 2>&1
  local i=0; for f in $(outputs $OUT/$name-gpp.log); do [[ -f $f ]] && cp $f $OUT/$name-gpp-$i.wav; i=$((i+1)); done
}

# speak <name> <seed> <params json> <text> <gpp extra args (array name)> [inproc args…]
speak() {
  local name=$1 seed=$2 params=$3 text=$4 extra=$5; shift 5
  gpp $name audio.speak $seed $params --text "text=$text" ${(P)extra}
  $INPROC speak --seed $seed --text "$text" --models-root "$MODELS" --out $OUT/$name-inproc.wav "$@" 2>> $LOG | tail -1 > $OUT/$name-inproc.json
  say "      $name: over GPP $(grep -o 'ran in [0-9.]* s' $OUT/$name-gpp.log | head -1); in-process $(cat $OUT/$name-inproc.json)"
  same $name $OUT/$name-gpp-0.wav $OUT/$name-inproc.wav
}

NONE=(); CLONE=(--input "voice_ref=$REF"); CONT=(--input "voice_ref=$REF" --text "voice_ref_text=$REFTEXT")
EN='Gaea speaks. This sentence came from a signed plugin, over its own protocol.'
speak zero 42 '{}' "$EN" NONE
speak happy 3 '{"emotion":{"label":"happy"}}' 'We won! [pause 0.5s] I still can not believe it.' NONE --emotion happy
speak described 5 '{"emotion":{"description":"whispering, as if telling a secret"}}' 'Come closer. Nobody else can know.' NONE --emotion-description 'whispering, as if telling a secret'
speak chinese 11 '{"language":"zh"}' '今天天气很好，我们去公园散步吧。' NONE --language zh
speak clone 9 '{}' "$EN" CLONE --ref $REF
speak continuation 9 '{}' "$EN" CONT --ref $REF --ref-text "$REFTEXT"

DESC='A warm, low voice of a woman in her forties, unhurried, with a slight rasp.'
gpp design audio.design_voice 7 '{"count":2,"language":"en"}' --text "description=$DESC"
$INPROC design --description "$DESC" --count 2 --language en --seed 7 --models-root "$MODELS" --out-dir $OUT/design-inproc 2>> $LOG | tail -1 > $OUT/design-inproc.json
say "      design: over GPP $(grep -o 'ran in [0-9.]* s' $OUT/design-gpp.log | head -1); in-process $(cat $OUT/design-inproc.json)"
same "design sample 0 (seed 7)" $OUT/design-gpp-0.wav $OUT/design-inproc/samples-0.wav
same "design sample 1 (seed 8)" $OUT/design-gpp-1.wav $OUT/design-inproc/samples-1.wav
SAMPLETEXT=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['text'])" $OUT/design-inproc.json)
DESIGNED=(--input "voice_ref=$OUT/design-gpp-0.wav" --text "voice_ref_text=$SAMPLETEXT")
speak designed-clone 13 '{}' 'The clone reads a new line now, in the voice it was given.' DESIGNED --ref $OUT/design-gpp-0.wav --ref-text "$SAMPLETEXT"

for s in $OUT/*.gpp; do
  if python3 ${GAEA_SPEC_ROOT:-$ROOT/../gaea-mes-media-server}/tools/validate.py --transcript $s >> $LOG 2>&1; then pass=$((pass+1)); say "PASS  ${s:t} passes validate.py"
  else fail=$((fail+1)); say "FAIL  ${s:t} fails validate.py"; fi
done
say "== $pass passed, $fail failed"
exit $(( fail > 0 ))
