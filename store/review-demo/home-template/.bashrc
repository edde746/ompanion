# The review demo's shell. The app opens login shells, so .profile sets the PATH for them and this file
# covers interactive non-login shells.
export PATH="$HOME/.local/bin:$PATH"
export PS1='review@ompanion-demo:\w\$ '
