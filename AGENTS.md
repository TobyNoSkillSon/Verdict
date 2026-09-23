# Installing Verdict (for coding agents)

Your user asked you to install Verdict: a menu-bar app that keeps local decision models loaded so you can judge many items in milliseconds. Do this, then tell them what you did.

1. **Check.** Apple Silicon Mac, macOS 14+, `python3` 3.12–3.14, Apple Command Line Tools (`xcode-select -p`). If one is missing, tell the user the one command that fixes it and stop.
2. **Install.** From this repository: `scripts/install.sh`. It builds the app, puts it in `/Applications` (or `~/Applications`), starts it, and waits until a model is loaded. It prints a few short lines and ends with `ready: …`. First run downloads ~1 GB (runtime + Laya English); allow several minutes.
3. **Give yourself the skill.** `verdict skill --install <your skills folder>` — for example `~/.claude/skills` (Claude Code), `~/.codex/skills` (Codex), `~/.pi/agent/skills` (Pi), or a project's `.agents/skills`. `verdict skill` prints it instead. Read it once; it tells you when Verdict is worth using and how to write questions.
4. **Verify.** `verdict status` should list a model with `(mlx)`. Then:
   `python3 -c "import sys,os; sys.path.insert(0, os.path.expanduser('~/.local/share/verdict')); from verdict import judge, Noul; print(judge('please refund me', {'refund': Noul('Does the writer ask for money back?')}))"`
5. **Report** in one or two lines: installed, which model is hot, memory from `verdict status`. Ask whether they want **Launch at Login** (menu → Launch at Login); do not enable it yourself.

Updating: `git pull && scripts/install.sh`. Models, settings and the runtime are kept. Uninstall: quit the app, delete it, `~/Library/Application Support/Verdict`, `~/.local/bin/verdict` and `~/.local/share/verdict`.

Output is plain and short by design: `verdict judge` prints one line per item (`#index  name=value …  | snippet`); add `--json` only when you need every probability.
