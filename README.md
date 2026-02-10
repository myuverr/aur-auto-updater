# AUR Auto Updater

A GitHub Action workflow to automate AUR package updates.  
Detects new upstream versions, updates `pkgver`/`sha256sums`, and pushes to AUR.

## Configuration

Set these in repository Secrets/Variables:

* **Secrets**
  * `AUR_SSH_KEY`: Private SSH key for AUR.
  * `GH_PAT`: GitHub PAT (for read-only access to public repos).
* **Variables**
  * `PACKAGES_CONFIG`: JSON package list.

**PACKAGES_CONFIG Example:**

```json
{
  "package-name": {
    "github": "upstream-owner/repo",
    "use_latest_release": true,
    "prefix": "v"
  },
  "another-package": {
    "github": "upstream-owner/other-repo",
    "use_max_tag": true,
    "include_regex": "^v[0-9.]+$"
  }
}
```

## License

This project is licensed under the [Mozilla Public License 2.0](LICENSE).
