approval_status: approved

# Install official oak CLI 1.1.1

- Approved package: `opencode-agent-orchestration-kit@1.1.1`
- Exact approved command: `npm install --global opencode-agent-orchestration-kit@1.1.1`
- Scope: Global npm installation.
- Source: npm package `opencode-agent-orchestration-kit` and upstream repository `https://github.com/jcarlosrodicio/opencode-agent-orchestration-kit`.
- Approval: User explicitly approved the exact pinned package/version and global npm environment change.
- Approval status: `approved`.
- OpenCode v2 acceptance: After being informed that OpenCode v2 support is experimental, the user replied “continue” and confirmed proceeding with this same exact pinned package under that compatibility tradeoff.
- Prerequisite check: Node `v24.21.0` and npm `11.19.0` satisfy the package's declared Node engine (`^22.9.0 || ^24.0.0`). Installed OpenCode is `v2.0.20`; official v1.1.1 source reports OpenCode v1 `>=1.14.41 <2.0.0` and experimental v2 `>=2.0.18 <3.0.0`.
- Installation: `npm install --global opencode-agent-orchestration-kit@1.1.1` succeeded (`changed 1 package in 183ms`). Installed package metadata confirms name/version `opencode-agent-orchestration-kit@1.1.1`, Node engine `^22.9.0 || ^24.0.0`, and `oak` binary.
- Verification: `oak version` reports `opencode-agent-orchestration-kit 1.1.1`; `oak --help` succeeds. `oak doctor` reports OpenCode 2.0.20 as supported experimentally and Node 24.21.0 supported, but exits 1 with a `file-drift` action-required status. Ambient shell `PATH` omits npm's global bin (`$(npm prefix -g)/bin`); checks succeeded after temporarily prepending that directory to `PATH`. Compatibility metadata declares OpenCode v1 `>=1.14.41 <2.0.0` and v2 `>=2.0.18 <3.0.0` experimental.
- Configuration/delivery: `oak install` was not run; no delivery, PR, or push command was run.
