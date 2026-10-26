# Google Antigravity AppImage

An unofficial AppImage for Google Antigravity on Linux.

Since Google only distributes Antigravity as a `.tar.gz`, this repository automatically packages it into an AppImage whenever a new version is released.

## How to Run

1. Go to **[Releases](../../releases)** and download the `.AppImage` matching your CPU architecture (`uname -m`): `x86_64` for Intel/AMD, `aarch64` for ARM64.
2. Make it executable and run it:

```bash
chmod +x Antigravity-*.AppImage
./Antigravity-*.AppImage
```

You can also use tools like **Gear Lever** or **AppImageLauncher** if you want it to show up automatically in your application menu.

### Updates
This AppImage supports delta updates. If you use **Gear Lever** or **AppImageUpdate**, you can update directly without re-downloading the full file.

---

## Disclaimer

This is an unofficial, community-maintained project. It is not affiliated with, sponsored by, or endorsed by Google. All trademarks, logos, and binaries belong to Google LLC.

## License

The build scripts and workflows in this repository are licensed under the [MIT License](LICENSE).
