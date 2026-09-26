# Security policy

## Reporting a vulnerability

Report it privately through GitHub: https://github.com/TobyNoSkillSon/Verdict/security/advisories/new (the repository's **Security** tab → **Report a vulnerability**). Please do not open a public issue, discussion or pull request for it.

Include the Verdict version (`verdict --version`), your macOS version and chip, and the smallest request or steps that show the problem. The conversation stays in the private advisory. A fix ships in a new release, and the advisory is then published with credit to you unless you ask otherwise.

Only the latest release receives security fixes.

## What Verdict exposes

Verdict's helper serves an HTTP API on the IPv4 loopback address (`127.0.0.1`) at a port chosen at launch. It has no authentication, by design: any process running as any user on the Mac can call it, and nothing off the Mac can reach it. It refuses what a web page could send. A request with an `Origin` header, a `Host` other than `127.0.0.1:<port>` or `localhost:<port>`, or a POST whose `Content-Type` is not `application/json` is rejected before its body is read. [docs/API.md](docs/API.md) describes these checks.

Its network traffic is the release download at install time and model weights from Hugging Face on first use. There is no telemetry.

## In scope

- A way for a web page, another machine or anything else outside the Mac to reach or drive the API: bypassing the `Origin`, `Host` or `Content-Type` checks, DNS rebinding, or the helper listening beyond loopback.
- A request that reads, writes or deletes files outside Verdict's own support directory and model cache, or runs code (for example through a crafted model id, path or tokenizer file).
- Memory corruption or a crash of the helper caused by the contents of a request.
- Weaknesses in the installer or the release: installing an app whose SHA-256, code signature or build attestation does not match, or running downloaded code before it is verified.
- Secrets or judged text written where other users of the Mac can read them.

## Out of scope

- Other processes on the same Mac calling the API. That is how it is meant to work (see above), including a local process using it heavily or unloading models.
- Answers that are wrong or can be manipulated by the judged text (prompt injection). The models judge whatever text they are given, and the README lists their known weak spots. Treat Verdict as one layer of a check, never the only one.
- Forwarding the port to other machines yourself.
- Gatekeeper warnings about the ad-hoc signature when the zip is downloaded through a browser. The installer downloads it with curl instead.
- Vulnerabilities in dependencies (MLX, swift-transformers and others) with no Verdict-specific impact. Please report those upstream; tell us if Verdict needs to update.
