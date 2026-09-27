# ompanion review demo

This machine runs [omp](https://github.com/can1357/oh-my-pi), the coding agent ompanion is a client for, with
one model: GLM 5.3 Flash through OpenRouter, on an account the ompanion developer pays for.

- Add the machine in ompanion: SSH, this server's address, port 22, user `root`, authentication Password.
- Open a session in `~/work/notes-api` — a small TypeScript service with a git history — and ask for
  anything: explain the code, change a file, run a command.

This server exists only for the review. Everything in this home is put back by the demo's reset command,
which also stops the sessions omp is running.
