# AUR Auto Updater

A GitHub Action workflow to automate AUR package updates.  
Detects new upstream versions, updates `pkgver`/`sha256sums`, and pushes to AUR.

## Configuration

Set these in repository Secrets/Variables:

* **Secrets**
  * `AUR_SSH_KEY`: Private SSH key for AUR.
  * `AUR_GIT_USER`: Git identity for AUR commits, format: `Name <email>`.
  * `GH_PAT`: GitHub PAT (for read-only access to public repos).
* **Variables**
  * `PACKAGES_CONFIG`: nvchecker package sections (TOML).

**PACKAGES_CONFIG Example:**

```toml
[package-a]
source = "github"
github = "owner-a/repo-a"
use_latest_release = true

[package-b]
source = "github"
github = "owner-b/repo-b"
use_max_tag = true
include_regex = "^v[0-9.]+$"
prefix = "v"
```

> **Note:** `PACKAGES_CONFIG` must contain only `[package-name]` table sections.
> `[__config__]` is auto-generated and will be ignored if present.
> Top-level scalar or array keys (e.g. `foo = "bar"`) will also be ignored.

## License

This project is licensed under the [Mozilla Public License 2.0](LICENSE).
