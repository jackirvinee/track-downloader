# Track Downloader Public Release Checklist

This checklist turns the [security model](SECURITY_MODEL.md) into a publication sequence. It does not authorize publication. Creating a GitHub repository, changing its visibility, enabling account settings, publishing a release, or distributing a signed binary remains a separate maintainer decision.

## Expected timeline

For a source-only first release, plan on roughly **3 to 7 focused working days** after the local hardening is complete:

1. **One day:** freeze and inspect the exact curated source tree.
2. **One day:** create a private staging repository and configure its security controls.
3. **One to three days:** run clean-clone tests, CodeQL, dependency review, and a human security review; fix anything found.
4. **One day:** verify documentation, identity, license, and disclosure paths, then make the explicit public/private decision.

Allow more time if the review finds old credentials, personal material, unclear licensing, or dependencies that need replacement. A signed and notarized binary release is a separate project and normally adds at least one to two weeks for signing, packaging, clean-account installation, update/rollback, and release-pipeline validation.

## Gate 1: Freeze the source revision

- [ ] All intended changes are committed to one reviewed local revision.
- [ ] Full Swift and Python suites pass from isolated build caches.
- [ ] Browser-cookie access is absent by default and requires an explicit local operator choice.
- [ ] Swift and Python accept only supported HTTPS hosts.
- [ ] Extractor-reported and discovered paths remain inside the configured output root after symlink resolution.
- [ ] The loopback web UI binds only to `127.0.0.1`, requires its per-launch token for mutations, and bounds JSON input.
- [ ] The optional local-test Chrome companion keeps its narrow permission contract, passes its native-message tests, and remains unpublished pending a separate extension security review.

Record the immutable commit SHA in the release review. Do not use a moving branch name as proof of what was inspected.

## Gate 2: Build a curated candidate, not a copy of private history

The current development history contains internal planning material and must not be made public by changing repository visibility or pushing all refs. Create a new source-only candidate from an explicit allowlist. One safe pattern is:

```bash
set -euo pipefail
candidate_root="$(mktemp -d /tmp/track-downloader-public.XXXXXX)"
candidate_dir="$candidate_root/candidate"
python3 script/create_public_release_candidate.py --revision HEAD --output "$candidate_dir"
python3 script/open_source_guard.py --candidate "$candidate_dir"
python3 script/verify_public_release_tree.py "$candidate_dir"
```

This exports exact allowlisted blobs from the reviewed commit only. It deliberately omits private development history and internal planning directories. Inspect the candidate manually even when the checker passes; pattern-based scanners cannot prove that prose, images, or ordinary-looking source contain no private information.

- [ ] `script/verify_public_release_tree.py` reports no findings for the candidate.
- [ ] The candidate contains no `.git`, `.codex`, `.agents`, `.superpowers`, `docs/superpowers`, artifacts, worktrees, generated executables, signatures, logs, archives, cookies, media, `.env` files, or build caches.
- [ ] Search the candidate for names, email addresses, usernames, absolute paths, machine names, account identifiers, private URLs, and organization details. Keep only intentional public identity.
- [ ] Review every image and binary resource; scanners cannot reliably detect personal information inside them.
- [ ] Run at least one independent high-confidence secret scan and manually inspect its findings.
- [ ] Confirm the MIT copyright holder and `pyproject.toml` author are intentional public information.
- [ ] Initialize the candidate as a brand-new repository with a single initial commit. Do not attach or push the private repository's refs, tags, reflogs, or objects.

## Gate 3: Protect the maintainer account

- [ ] Use a unique password plus a passkey or hardware security key; store recovery codes offline. GitHub documents current options in [About two-factor authentication](https://docs.github.com/en/authentication/securing-your-account-with-two-factor-authentication-2fa/about-two-factor-authentication).
- [ ] Review active sessions, SSH keys, deploy keys, OAuth apps, GitHub Apps, and personal access tokens. Revoke anything unused or unfamiliar.
- [ ] Prefer short-lived, fine-grained tokens limited to this repository; never put a token in source, shell history, issue text, workflow YAML, or screenshots. See [Managing personal access tokens](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens).
- [ ] Keep signing/notarization credentials out of the source repository and ordinary pull-request workflows.
- [ ] Decide which author name, noreply email, profile details, and public support contact you intend to expose before creating the first public commit.

Public source will reveal architecture, dependencies, naming, and coding style. That is not a credential. The defense is to ensure those facts grant no authority: no embedded secrets, private network addresses, personal absolute paths, account identifiers, reusable tokens, cookie material, or privileged workflow route should depend on obscurity.

## Gate 4: Configure the staging repository while it is private

- [ ] Confirm `.github/CODEOWNERS` names the actual repository owner or a visible team with write access. A file alone does not enforce review; enable required code-owner review. See [About code owners](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-code-owners).
- [ ] Add an active ruleset for `main`: require pull requests, at least one approval from someone other than the last pusher when available, dismiss stale approvals, resolve review threads, require CI and CodeQL, block force pushes, and restrict deletion. Keep bypass access empty or extremely narrow. See [Available rules for rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets).
- [ ] Set Actions workflow permissions to read-only by default and disable automatic approval of pull requests by workflows.
- [ ] Require approval before workflows from new or untrusted fork contributors run. Never use a self-hosted runner connected to the maintainer's Mac for public pull requests.
- [ ] Enable secret scanning and push protection; remove a real secret instead of bypassing the warning. See [Push protection](https://docs.github.com/en/code-security/concepts/secret-security/push-protection) and [secret scanning](https://docs.github.com/en/code-security/how-tos/secure-your-secrets/detect-secret-leaks/enable-secret-scanning).
- [ ] Enable Dependabot alerts/updates and verify the committed monthly configuration is active.
- [ ] Enable private vulnerability reporting and test that the private report button is visible. See [Configuring private vulnerability reporting](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/configure-vulnerability-reporting/configure-for-a-repository).
- [ ] Disable unused repository features and integrations. Give every installed app the least repository and organization access possible.

## Gate 5: Treat contributions as proposals, not installed code

A stranger cannot directly place code in the official branch unless they receive write authority or a maintainer merges it. A pull request is a proposed diff. The safe contribution path is:

1. The contributor changes only their fork.
2. GitHub-hosted CI runs with a read-only token and no maintainer secrets.
3. CODEOWNERS requests review; rulesets prevent direct or unreviewed merge.
4. A maintainer reviews source, tests, workflow permissions, dependency changes, generated files, and the complete diff.
5. Required checks pass on the exact reviewed commit.
6. The maintainer—not contributor-controlled automation—chooses whether to merge.

- [ ] Never run an unreviewed contributor script, installer, app bundle, package hook, or test on the personal development account.
- [ ] Review workflow and dependency changes before relying on their CI result; a malicious test can exfiltrate anything present on its runner.
- [ ] If local reproduction is necessary, use an isolated VM or non-sensitive test account with no browser sessions, signing keys, personal files, cloud credentials, or repository write token.
- [ ] Do not copy commands from issues without understanding every executable, argument, path, network destination, and destructive effect.
- [ ] Keep release jobs manual, protected, and unable to run from fork pull requests.

## Gate 6: Verify the exact public source

- [ ] Clone the new staging repository into a clean directory as an ordinary user.
- [ ] Re-run the public-tree checker against that clone, excluding only its new `.git` metadata from the candidate being audited.
- [ ] Run the full Swift and Python suites, Python syntax checks, Markdown-link checks, YAML parsing, CodeQL, and the source-bundle verification.
- [ ] Confirm every `uses:` reference is an official action pinned to a full 40-character commit SHA.
- [ ] Confirm CI logs and artifacts contain no local URLs, paths, tokens, cookies, downloaded media, or account data.
- [ ] Confirm the README describes a source release and does not imply notarization, signed distribution, platform authorization, or security settings that have not been verified.
- [ ] Have a second reviewer inspect the candidate if practical, especially `.github/`, build/install scripts, executable resolution, cookie handling, and path containment.

## Gate 7: Public decision and first-week monitoring

- [ ] Record the candidate commit SHA, test evidence, settings evidence, and known limitations.
- [ ] Decide explicitly whether to change the new repository from private to public. Do not reuse the private development repository.
- [ ] Publish source only. Do not attach the locally ad-hoc-signed app as an official binary.
- [ ] For the first week, monitor security alerts, Actions runs, dependency alerts, new issues, and pull requests daily.
- [ ] Triage suspicious contributions without executing them locally. Lock or redact public material that exposes credentials or another person's private data.
- [ ] If a credential appears publicly, revoke it first, then investigate and remove what can be removed; assume public Git objects may already have been copied.

## Separate signed-binary gate

Do not publish a signed or notarized app until signing identities are isolated from ordinary CI, release tags and environments are protected, dependencies and entitlements are verified, installation/update/rollback are tested from a clean macOS account, and the downloadable artifact is independently matched to its source revision and published hash.

## Separate GitHub update-release gate

The dormant update notice is source-complete only when its source and tests are part of the curated candidate. It does not authorize a tag, GitHub Release, binary upload, visibility change, signing, notarization, or publication.

- [ ] Choose and commit the release version separately. The normalized `CFBundleShortVersionString`, stable Git tag, GitHub `tag_name`, displayed version, and asset version must agree.
- [ ] Confirm the GitHub Release is neither a draft nor a prerelease; otherwise GitHub's `/releases/latest` endpoint must not expose it to the app.
- [ ] Name the release asset exactly `Track-Downloader-X.Y.Z.app.zip`. It must contain exactly one top-level `Track Downloader.app`, never a version-suffixed app name.
- [ ] Verify the archive's bundle identifier remains `com.jackirvine.trackdownloader`, and that its executable, plist, and signature pass the repository bundle checks.
- [ ] Keep release notes concise enough for the in-app four-line preview; retain the complete notes on the GitHub Release page.
- [ ] From a non-sensitive macOS account, verify the public endpoint, returned exact `html_url`, browser action, asset link, Finder **Replace** prompt, and retained downloads/preferences.
- [ ] Recheck offline, malformed-response, private/404, and rate-limit behavior against the actual release build.
- [ ] Keep repository visibility, Release creation/publication, signing/notarization, and any ready-to-use binary distribution as separate maintainer approvals.
