# Security Policy

## Supported versions

CamillaEQApp is currently maintained as a pre-1.0 project. Security fixes are
provided for the latest release only. Before reporting a problem, please check
whether it is still present in the newest release or the current default branch.

| Version | Supported |
| --- | --- |
| Latest release | Yes |
| Current default branch | Yes |
| Older releases | No |

CamillaEQApp supports macOS 13 Ventura and newer. Reports that only affect an
unsupported macOS version may not receive a fix.

## Reporting a vulnerability

Please do not disclose a suspected vulnerability in a public issue, discussion,
pull request, or social-media post.

Use the repository's [private vulnerability reporting
form](https://github.com/Shuail135/CamillaEQApp/security/advisories/new). If the
form is unavailable, open a public issue containing no security-sensitive
details and ask the maintainer to arrange a private reporting channel.

Include as much of the following as possible:

- The affected CamillaEQApp version or commit.
- Your Mac model, processor architecture, and macOS version.
- A clear description of the vulnerability and its potential impact.
- Reproduction steps or a minimal proof of concept.
- Relevant logs, crash reports, or screenshots with personal information,
  device identifiers, access tokens, and file paths removed.
- Any known mitigations or suggested fixes.

Do not include private audio recordings, credentials, signing keys, or other
people's data in a report.

## What to expect

The maintainer will make a best effort to:

- Acknowledge a complete report within seven days.
- Confirm whether the issue is accepted, needs more information, or is outside
  the project's scope.
- Provide progress updates while an accepted report is being investigated.
- Coordinate a fix and public disclosure with the reporter.

Please allow reasonable time for investigation and release of a fix before
publishing technical details. Response and remediation times depend on severity,
complexity, and maintainer availability; they are not guaranteed.

## Scope

Security reports may cover:

- The CamillaEQApp application and its local configuration handling.
- The bundled System Audio Bridge Core Audio driver and app-driver transport.
- Dependency download, verification, installation, and privileged setup flows.
- Audio routing behavior that crosses an expected privacy or security boundary.

Ordinary bugs, feature requests, audio-quality problems, and expected macOS
Gatekeeper warnings for ad-hoc-signed development builds should use the public
issue tracker. Vulnerabilities in an upstream dependency should also be reported
to that upstream project; please report them here as well when CamillaEQApp's
integration makes users exploitable.

## Safe-harbor intent

Good-faith research that avoids privacy violations, data destruction, service
disruption, and access beyond what is necessary to demonstrate the issue is
welcome. The project will not pursue action against researchers who follow this
policy and applicable law.
