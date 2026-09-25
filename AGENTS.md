# Installing Verdict (for coding agents)

Your user asked you to install Verdict: a menu-bar app that keeps local decision models loaded so you can judge many items in milliseconds. Do this, then tell them what you did.

1. **Check.** Apple Silicon Mac, macOS 14+, and `python3` for the CLI (macOS's own is fine). The installer checks and prints the one command that fixes anything missing — pass it to the user and stop.
2. **Install.** From this repository: `scripts/install.sh`. It downloads the prebuilt app for this version with curl, verifies its SHA-256 and signature, puts it in `/Applications` (or `~/Applications`), starts it, and waits until a model is loaded. It prints a few short lines and ends with `ready: …`. First run downloads ~0.8 GB (Laya English). Never download the zip through a browser.
3. **Install the skill into your own harness.** `verdict skill` prints it (`verdict skill --install DIR` writes `DIR/triage/SKILL.md` if your harness uses skill folders). Put it wherever your harness keeps skills, the way you normally would. Read it once; it tells you when Verdict is worth using and how to write questions.
4. **Verify.** `verdict status` should list a model with `(Optimized · <chip>)` (Verdict's optimized path passed its self-test on this Mac) or `(MLX: <reason>)` (the stock path: it works, more slowly). Then:
   `python3 -c "import sys,os; sys.path.insert(0, os.path.expanduser('~/.local/share/verdict')); from verdict import judge, Noul; print(judge('please refund me', {'refund': Noul('Does the writer ask for money back?')}))"`
5. **Report** in one or two lines: installed, which model is hot, memory from `verdict status`. Ask whether they want **Launch at Login** (menu → Launch at Login); do not enable it yourself.

Updating: `git pull && scripts/install.sh`. Models and settings are kept; an idle Verdict is quit and restarted automatically. Uninstall: quit the app, delete it, `~/Library/Application Support/Verdict`, `~/.local/bin/verdict` and `~/.local/share/verdict`.

Output is plain and short by design: `verdict judge` prints one line per item (`#index  name=value …  | snippet`); add `--json` only when you need every probability.
