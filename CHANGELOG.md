# Changelog

## 3.2.10

- Fix false E2E failures on the tested Ubuntu host by disabling TX checksum offload on the two temporary veth interfaces only; physical interfaces are untouched.
- Install/check `ethtool` automatically and restore the external-DNS interception test alongside the configured DNS query.
- Bind test DNS sockets to the temporary peer address and allow bounded DNS retries during tunnel startup.
- Verified the failing/successful cases on the affected host; full WireGuard DNS, HTTP and HTTPS validation is required before committing routing.

## 3.2.9

- Capture temporary peer handshake and DNS NAT counters when the client-path DNS check fails.

## 3.2.8

- Prime the temporary WireGuard tunnel before client-path DNS checks and query the DNS address used in actual client profiles.

## 3.2.7

- Include the DNS response in end-to-end diagnostics when the temporary WireGuard client DNS probe fails.

## 3.2.6

- Print the exact failing command when the temporary WireGuard end-to-end check fails.

## 3.2.5

- Preserve and report `dig` output when the DNS probe exits unsuccessfully, instead of aborting before diagnostics.

## 3.2.4

- Retry transient DNS readiness failures after Xray/Unbound restart and report the final DNS response in diagnostics.

## 3.2.3

- Fix E2E test failure on hosts already using the former fixed `192.0.2.0/30` test subnet.
- Allocate an unused RFC 5737 `/30`, unique interface and namespace names, and a free WireGuard test peer address; always clean up only the test resources.
- Ignore wg0's own `10.66.66.1/24` interface address when selecting a temporary peer IP.
- Prevent recursive rollback diagnostics when the E2E subshell fails.

## 3.2.2

- First GitHub publication of PD - Xray WG Manager.
- Quick setup configures the gateway only; create clients separately with option 6.
- Accept plain validity days (`30`) as well as `+30` and calendar dates.
- Validate client limits before creating peers; retry invalid input.
- Display saved configs/QR codes on creation, duplicate-name selection and option 15.
- Include automatic Unbound installation, authenticated upstream selection, Xray readiness checks, pre-rollback diagnostics and traffic/expiry limits.
- Persian and English installation/operation documentation.

- Ignore wg0's own 10.66.66.1/24 interface address when selecting a temporary peer IP.
- Prevent recursive rollback diagnostics when the E2E subshell fails.
