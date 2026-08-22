# Security policy

## Supported versions

Labstream is pre-release software. Security fixes are applied to the latest `main` branch and,
when practical, the most recent published build. Older commits, local development builds, and
unofficial distributions are not supported release channels.

## Report a vulnerability privately

Do **not** open a public issue or Discussion for a suspected vulnerability. Use
[GitHub private vulnerability reporting](https://github.com/jlipworth/Labstream/security/advisories/new).
If that form is unavailable, wait for it to be restored rather than posting sensitive details in
public; ordinary support issues cannot provide a private security channel.

Include only the minimum information needed to reproduce the problem. Do not include real media
titles, library paths, server names or addresses, usernames, access tokens, client identifiers,
signing material, or unreviewed logs. Use synthetic placeholders and the app's redacted diagnostic
preview where possible.

The maintainer will acknowledge a usable report, assess impact, coordinate a fix and disclosure,
and credit the reporter if requested. Response times are best-effort because this is a
maintainer-run open-source project.

## Scope

Useful reports include credential disclosure, authorization bypass, unsafe URL or media parsing,
private-data leakage, insecure update or signing behavior, and CI/release workflow compromise.
Configuration help and ordinary playback failures belong in the public support channels after
private values have been removed.
