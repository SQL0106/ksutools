#!/usr/bin/env bash
# Fetch oh-my-zsh + enhancement plugins and vendor them into the module tree.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MOD="$(cd "$HERE/.." && pwd)/module"
SRC="$HERE/omz-src"
OMZ="$MOD/system/usr/share/oh-my-zsh"

clone() {
  local url="$1" dst="$2"
  if [ -d "$dst/.git" ]; then
    git -C "$dst" pull --ff-only -q
  else
    rm -rf "$dst"
    git clone --depth=1 -q "$url" "$dst"
  fi
  rm -rf "$dst/.git"
}

mkdir -p "$SRC"
clone https://github.com/ohmyzsh/ohmyzsh.git "$SRC/ohmyzsh"

# enhancement plugins (zsh-users)
clone https://github.com/zsh-users/zsh-autosuggestions.git        "$SRC/p/zsh-autosuggestions"
clone https://github.com/zsh-users/zsh-syntax-highlighting.git     "$SRC/p/zsh-syntax-highlighting"
clone https://github.com/zsh-users/zsh-completions.git             "$SRC/p/zsh-completions"
clone https://github.com/zsh-users/zsh-history-substring-search.git "$SRC/p/zsh-history-substring-search"

# install oh-my-zsh
rm -rf "$OMZ"
mkdir -p "$(dirname "$OMZ")"
cp -a "$SRC/ohmyzsh" "$OMZ"
mkdir -p "$OMZ/custom/plugins"
for p in zsh-autosuggestions zsh-syntax-highlighting zsh-completions zsh-history-substring-search; do
  rm -rf "$OMZ/custom/plugins/$p"
  cp -a "$SRC/p/$p" "$OMZ/custom/plugins/$p"
done

echo "=== oh-my-zsh installed ==="
du -sh "$OMZ"
ls "$OMZ/custom/plugins"
