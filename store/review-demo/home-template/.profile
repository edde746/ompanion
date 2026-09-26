# Login shells get the same PATH as .bashrc: ~/.local/bin is where the app looks for omp first, and it is
# where this image links the pinned release.
export PATH="$HOME/.local/bin:$PATH"
if [ -f "$HOME/.bashrc" ]; then . "$HOME/.bashrc"; fi
