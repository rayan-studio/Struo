# Releasing Struo

Written for whoever cuts a release. Users want
[installing and updating](#for-users) at the bottom.

## What a release is

A tag `v<version>` on `main`. Pushing it runs
[`.github/workflows/release.yml`](../.github/workflows/release.yml), which
tests, packages every platform, proves each archive installs, and publishes a
GitHub Release with the artifacts attached.

That published release is what `struo self-update` reads. Publishing one is
therefore the act that offers the update to everybody who has Struo installed,
and it is deliberately not something a push to `main` can do by accident.

## Cutting one

1. **Bump the version.** `CStruoVersion` in
   [src/core/Struo.Types.pas](../src/core/Struo.Types.pas) is the only copy.
   Commit it.

2. **Tag it to match.** The workflow compares the tag against that constant
   and fails the release if they disagree:

   ```console
   $ git tag v0.2.0
   $ git push origin v0.2.0
   ```

   The check is not pedantry. `struo self-update` downloads the archive, runs
   the binary inside it, and refuses the update when the version it reports is
   not the one the release promised — which is exactly the right behaviour for
   a corrupt download, and would be maddening if a mismatched tag caused it.

3. **Watch the run.** If a platform's archive cannot compile, link and run a
   test program, that job goes red and nothing is published. See
   [when a release fails](#when-a-release-fails).

A version with a hyphen in it — `0.3.0-beta.1` — is published as a
prerelease, so `struo self-update` will not offer it: that command reads
`/releases/latest`, which skips prereleases.

## Trying it without publishing

Every push to `main` builds the same artifacts and keeps them as workflow
artifacts for 14 days, so there is always something installable attached to
each commit. Nothing is published.

To rehearse the publishing half, run the workflow by hand from the Actions tab
with **Publish a GitHub Release** ticked. It will publish `v<CStruoVersion>`.

Locally, the packaging scripts do everything the workflow does except upload:

```console
$ ./packaging/release.ps1                 # Windows: .zip + setup.exe
$ ./packaging/release.sh                  # Linux, macOS: .tar.gz
$ ./packaging/release.ps1 -SkipArchive    # stage only, to inspect the tree
$ ./packaging/release.sh --full           # every Free Pascal unit package
```

Both refuse to produce an archive whose bundled toolchain cannot compile, link
and run a test program. An archive that reaches `dist/` has been proved to
work on the machine that built it.

## What ends up in a release

| Asset | For |
| --- | --- |
| `struo-<version>-<target>-setup.exe` | Windows, the ordinary way |
| `struo-<version>-<target>.zip` | Windows, unpack it yourself |
| `struo-<version>-<target>.tar.gz` | Linux and macOS, with `install.sh` inside |

Each carries Free Pascal; see [the toolchain](toolchain.md). The Windows
installer installs per user, into `%LOCALAPPDATA%`, and not into Program Files
— `struo self-update` replaces the binary and the toolchain in place, and can
only do that where the person running it can write. Anyone who wants a
machine-wide install can still choose it in the installer.

## When a release fails

The jobs are ordered so that a failure tells you where the problem is.

| Job that failed | What it means |
| --- | --- |
| **Test before packaging** | Ordinary test failure. Nothing was packaged. |
| **Package** | The platform's archive could not be built, or its bundled toolchain could not compile. The step log has the compiler's diagnostics. |
| **A user's first five minutes** | The archive built but does not work unpacked: the usual cause is a unit package missing from the curated list in `release.ps1` and `release.sh`. |
| **Publish** | Usually the tag and `CStruoVersion` disagreeing. |

A re-run after fixing one platform replaces that release's assets rather than
failing, so there is no need to delete the release by hand.

## Adding a platform

The matrix in `release.yml` has one entry per platform. A new one needs:

1. A runner and a way to install Free Pascal on it. Linux uses `apt`; Windows
   downloads the official installer and runs it silently, because Chocolatey's
   package lags and has shipped without the packaged units, which is the whole
   point of bundling a toolchain.
2. `packaging/release.sh` to work there. It builds the bundled layout from
   whatever shape the local Free Pascal install has, asking `fpc -PB` where
   the compiler binary really is, so a new Unix should need nothing.
3. Nothing in Struo itself: the asset name comes from the compiler's own
   target, through `Struo.Release.HostTargetName`.

macOS is not in the matrix yet. The blocker is not packaging but
`Struo.Paths.StruoExecutablePath`, which resolves a symlinked binary through
`/proc/self/exe` on Linux and falls back to `argv[0]` elsewhere — enough for a
directly-invoked binary, not for the symlink `install.sh` creates.

## For users

```console
$ struo self-update --check     # is there a newer Struo?
$ struo self-update --dry-run   # download and verify it, install nothing
$ struo self-update             # install it
```

Struo also mentions a new release itself, once a day at most, after commands
where a brief network call cannot be felt — never after `build`, `run` or
`test`, never in a script or a CI job, and never when `--quiet` is passed.
`STRUO_NO_UPDATE_CHECK=1` turns it off for good.

What an update does, in order: download the archive to a temporary file,
unpack it inside the installation directory, run the new binary and require
the version the release promised, and only then move the old binary and
toolchain aside and the new ones into place. Everything before that last step
is undone by deleting one directory. The old files stay until the next run,
because nothing can delete the binary it is executing from.

`struo self-update` refuses on a build made with `bootstrap/`, since there is
no release archive such a build corresponds to; `git pull` is the update for
those.
