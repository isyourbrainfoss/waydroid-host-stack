# Integration tests

Run on a machine/phone with BlueZ:

```sh
./scripts/smoke-host.sh
# with bluetoothd and adapter:
sudo ./target/release/waydroid-bt-host --socket /tmp/wbt.sock
```

Guest tests require Waydroid + LXC mount + custom image:

```sh
./scripts/smoke-guest.sh
```
