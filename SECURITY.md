# Security policy

Track Downloader runs local executables, processes remote media and metadata, and can pass explicitly selected browser-session authority to `yt-dlp`. Please report suspected security issues responsibly. The broader trust boundaries and maintainer controls are documented in [SECURITY_MODEL.md](SECURITY_MODEL.md).

## Reporting a vulnerability

Do not publish exploit details, browser cookies, media URLs, account names, logs, or other sensitive information in a public issue.

If this repository has GitHub private vulnerability reporting enabled, use it. Otherwise, open a public issue containing only a short request for a private reporting channel; a maintainer can then provide a secure contact path. Include no vulnerability details until a private channel is established.

In a private report, include the affected source revision, impact, reproducible steps, and the smallest safe proof of concept. Use generated data and a test account where possible. Do not send live credentials or cookies; describe the type of secret involved and coordinate a safe reproduction method.

## Scope

Useful reports include unintended network disclosure, unsafe handling of browser cookies or local paths, command injection, arbitrary file access, and bundled-release integrity issues. Reports about third-party platform availability or an upstream `yt-dlp` extractor change should be filed upstream when appropriate.

The project cannot authorize downloads or determine ownership of media. Reports that require bypassing DRM, paywalls, or access controls are out of scope. Do not test against accounts, systems, or content you do not own or have permission to use.

## Disclosure process

Please allow the maintainer a reasonable opportunity to validate and remediate a confirmed issue before publishing technical details. The maintainer will coordinate scope, remediation, release timing, and credit through the private channel. A report is not proof that a vulnerability exists until its behavior and impact have been reproduced against the identified revision.
