# Stakpak Autopilot Remote Installer

Generic Linux bootstrap script for installing Stakpak Autopilot on a reachable remote host.

The script is intentionally cloud-agnostic. Cloud-specific discovery/provisioning should happen before invoking this script and should produce a normal SSH target.

## Usage

Preferred env-var style, so secrets stay out of process arguments where possible:

```bash
curl -sSL https://raw.githubusercontent.com/noureldin-azzab/stakpak-autopilot-install/main/autopilot-install.sh | \
  STAKPAK_API_KEY='<api-key>' \
  STAKPAK_AUTH_PROVIDER='stakpak' \
  STAKPAK_MODEL='claude-opus-4-5-20251101' \
  sudo -E bash -s -- --skip-channels --target-user '<linux-user>'
```

With Slack notifications:

```bash
curl -sSL https://raw.githubusercontent.com/noureldin-azzab/stakpak-autopilot-install/main/autopilot-install.sh | \
  STAKPAK_API_KEY='<api-key>' \
  STAKPAK_AUTH_PROVIDER='stakpak' \
  STAKPAK_MODEL='claude-opus-4-5-20251101' \
  STAKPAK_NOTIFY_CHANNEL='slack' \
  STAKPAK_NOTIFY_CHAT_ID='#prod' \
  SLACK_BOT_TOKEN='<xoxb-token>' \
  SLACK_APP_TOKEN='<xapp-token>' \
  sudo -E bash -s -- --target-user '<linux-user>'
```

## Supported Linux OS IDs

- `amzn`
- `ubuntu`
- `debian`
- `rhel`
- `fedora`
- `rocky`
- `almalinux`
- `centos`

## Validation

```bash
bash -n autopilot-install.sh
```

