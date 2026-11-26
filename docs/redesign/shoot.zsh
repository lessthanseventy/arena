#!/usr/bin/env zsh
# Screenshots every direction's screens off-screen: arena-mock draws each frame as a page of cells
# at the human's Ghostty size (220×51 in an 1820×979 window, 22px padding, Comic Shanns 11pt), and a
# headless browser of this script's own session takes it.
# usage: zsh docs/redesign/shoot.zsh [direction …]   (from the repo, after `zig build`)
set -eu
here=${0:A:h}
mock=${here:h:h}/zig-out/bin/arena-mock
palette=$HOME/.config/ficciones/theme/palette.sh
pages=$(mktemp -d)
browse() { agent-browser --session arena-mock "$@" >/dev/null }

browse set viewport 1820 979
for dir in ${@:-phosphor workbench neon}; do
  for screen in home popup orch; do
    $mock $dir $screen $here/board.json $palette 220x51 $pages/$dir-$screen.html
    browse open file://$pages/$dir-$screen.html
    browse screenshot $here/$dir-$screen.png
    print $dir-$screen.png
  done
done
browse close
rm -r $pages
