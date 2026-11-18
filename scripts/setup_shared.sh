#!/usr/bin/env bash
# Create (or check) the group's shared RepairBench folder in the Foundry's shared scratch area,
# so model weights, task images, caches and results are stored once for everybody.
#
#   scripts/setup_shared.sh [folder] [--move <old work folder>]
#   folder defaults to /hpc/home/scratch/repairbench-java
#
# Run it once (any group member). Then everyone puts this line before `source scripts/env.sh`
# (e.g. in ~/.bashrc):   export RB_SHARED=/hpc/home/scratch/repairbench-java
#
# Folders get mode 3770 like /hpc/home/scratch itself: group members can add files and folders,
# new content keeps the group, nobody can delete or rename another person's files, and other
# users see nothing. Files you create are readable by the group, not writable (umask 0027,
# set by env.sh). Exception: cache/m2 and cache/gradle are one Maven/Gradle cache that many
# people add to, so their content is group-writable (warm_dependencies.sh uses umask 0007).
#
# --move <old work folder>: move what you already have (e.g. ~/repairbench-java/work) into the
# shared folder: model weights, task images and their caches. Anything already there is kept
# and your copy is left in place, so nothing is downloaded or pulled twice.
#
# Limits on the scratch area (VAST): soft 150 TB (30 days grace), hard 200 TB, for all users.
set -euo pipefail
DIR=/hpc/home/scratch/repairbench-java
MOVE=""
while (( $# )); do
  case $1 in
    --move) MOVE=${2:?--move needs the old work folder}; shift 2 ;;
    -h|--help) sed -n 2,22p "$0"; exit 0 ;;
    *) DIR=$1; shift ;;
  esac
done

PARENT=$(dirname "$DIR")
[[ -d $PARENT ]] || { echo "$PARENT does not exist (is this the Foundry?)" >&2; exit 1; }
GROUP=$(stat -c %G "$PARENT")
echo "shared folder: $DIR   group: $GROUP"
id -nG | tr ' ' '\n' | grep -qx "$GROUP" || echo "warning: you are not in group $GROUP; others may not see your files" >&2

umask 0027
SUBDIRS=(models images images/tasks cache cache/tasks cache/m2 cache/gradle runs)
mkdir -p "$DIR"
for d in "" "${SUBDIRS[@]}"; do
  p=$DIR/$d
  mkdir -p "$p"
  if [[ -O $p ]]; then                       # only the owner may set the mode
    chgrp "$GROUP" "$p" 2>/dev/null || true
    case $d in
      cache/m2|cache/gradle) chmod 2770 "$p" ;;   # one shared cache: no sticky bit
      *) chmod 3770 "$p" ;;
    esac
  fi
done

[[ -f $DIR/.rb-shared ]] || { printf 'RepairBench-Java shared folder\ncreated by %s on %s\n' \
  "${USER:-$(id -un)}" "$(date -Is)" > "$DIR/.rb-shared"; }

# check: every folder is group-writable, so every member can add to it
BAD=0
for d in "" "${SUBDIRS[@]}"; do
  p=$DIR/$d
  m=$(stat -c %a "$p")
  if [[ ! -w $p ]]; then echo "  NOT WRITABLE for you: $p (mode $m, owner $(stat -c %U "$p"))"; BAD=1
  else echo "  ok  $p  (mode $m, group $(stat -c %G "$p"))"; fi
done
(( BAD == 0 )) || { echo "ask the owner to run: chmod 3770 <folder>  (or this script)"; exit 1; }

if [[ -n $MOVE ]]; then
  [[ -d $MOVE ]] || { echo "--move: $MOVE is not a folder" >&2; exit 1; }
  movein() {  # movein <from> <to>: move if the target is not there yet, then make it group-readable
    local from=$1 to=$2
    [[ -e $from ]] || return 0
    if [[ -e $to ]]; then echo "  kept  $to (already there; your copy stays at $from)"; return 0; fi
    mv "$from" "$to"
    chgrp -R "$GROUP" "$to" 2>/dev/null || true
    chmod -R g+rX "$to"
    echo "  moved $from -> $to"
  }
  for m in "$MOVE"/models/*; do [[ -e $m ]] && movein "$m" "$DIR/models/$(basename "$m")"; done
  for s in "$MOVE"/images/*.sif; do [[ -e $s ]] && movein "$s" "$DIR/images/$(basename "$s")"; done
  for s in "$MOVE"/images/tasks/*; do [[ -e $s ]] && movein "$s" "$DIR/images/tasks/$(basename "$s")"; done
  for c in "$MOVE"/cache/tasks/*; do [[ -e $c ]] && movein "$c" "$DIR/cache/tasks/$(basename "$c")"; done
fi

echo
echo "ready. Everyone in $GROUP: add this line before 'source scripts/env.sh' (e.g. in ~/.bashrc):"
echo "  export RB_SHARED=$DIR"
