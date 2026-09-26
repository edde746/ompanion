# ompanion review demo

This machine runs [omp](https://github.com/can1357/oh-my-pi) with a fake model provider: every prompt is
answered with a canned reply, so nothing here needs an account, an API key or a payment method.

- Add the machine in ompanion: SSH, this server's address, port @PORT@, user `review`, authentication
  Password.
- Open a session in `~/work/notes-api` — a small TypeScript service with a git history — and send any
  prompt.
- The demo answers from a rotation: markdown, a shell command, a file read and an edit, a todo list,
  reasoning, a question, then a long streamed answer, and starts over.

`~/work/notes-api` is the same project the demo edits. Everything in this home is restored by the reset
command; running omp processes stop with it.
