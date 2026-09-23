# Installing Verdict (for coding agents)

Your user asked you to install Verdict: a menu-bar app that keeps local decision models loaded so you can judge many items in milliseconds. Do this, then tell them what you did.

1. **Check.** Apple Silicon Mac, macOS 14+, Apple Command Line Tools (`xcode-select -p`), and a Python 3.12–3.14 anywhere on the machine (the installer finds Homebrew's; macOS's own 3.9 does not count). The installer checks these and prints the one command that fixes whatever is missing — pass it to the user and stop.
2. **Install.** From this repository: `scripts/install.sh`. It builds the app, puts it in `/Applications` (or `~/Applications`), starts it, and waits until a model is loaded. It prints a few short lines and ends with `ready: …`. First run downloads ~1.4 GB (Python packages + Laya English); about a minute and a half on a fast connection.
3. **Install the skill into your own harness.** `verdict skill` prints it (`verdict skill --install DIR` writes `DIR/verdict/SKILL.md` if your harness uses skill folders). Put it wherever your harness keeps skills, the way you normally would. Read it once; it tells you when Verdict is worth using and how to write questions.
4. **Verify.** `verdict status` should list a model with `(mlx)`. Then:
   `python3 -c "import sys,os; sys.path.insert(0, os.path.expanduser('~/.local/share/verdict')); from verdict import judge, Noul; print(judge('please refund me', {'refund': Noul('Does the writer ask for money back?')}))"`
5. **Report** in one or two lines: installed, which model is hot, memory from `verdict status`. Ask whether they want **Launch at Login** (menu → Launch at Login); do not enable it yourself.

Updating: `git pull && scripts/install.sh`. Models, settings and the runtime are kept. Uninstall: quit the app, delete it, `~/Library/Application Support/Verdict`, `~/.local/bin/verdict` and `~/.local/share/verdict`.

Output is plain and short by design: `verdict judge` prints one line per item (`#index  name=value …  | snippet`); add `--json` only when you need every probability.
