# Repository workflow

- Treat `.godot`, build products, and raw test captures as local generated data.
- Commit source, tests, runtime pins, and compact evidence at each coherent,
  verified checkpoint. Use `python tools/create_checkpoint.py -m "message"`.
- Do not run timed or filesystem-watcher commits. A checkpoint must correspond
  to a reviewable state and should follow the relevant validation.
- Keep large raw evidence outside Git. Commit a small result document with the
  command, decisive measurements, and retained artifact location when needed.
- Preserve unrelated worktree changes and never hide source changes with
  `assume-unchanged` or `skip-worktree`.
