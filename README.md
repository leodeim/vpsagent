# vpsagent

`vpsagent` is the headless, open-source sender for VPSmon Cloud. It collects host metrics through [vpsmonlib](https://github.com/leodeim/vpsmonlib) and sends them over outbound HTTPS.

## Helper scripts

```bash
sudo /opt/vpsagent/update.sh
sudo /opt/vpsagent/remove.sh
```

`update.sh` checks the latest release, verifies its checksum, and restores the old binary if the service fails to start. `remove.sh` asks for confirmation and removes the local service and credential.