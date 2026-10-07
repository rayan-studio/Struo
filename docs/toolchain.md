# The toolchain

Struo ships with a Free Pascal installation inside it. You download one
archive, unpack it, and `struo build` works: nothing to install, no `PATH` to
arrange, and everyone on a given Struo release compiles with the same
compiler.

```console
$ struo toolchain
active  fpc 3.2.2   x86_64-win64   bundled   C:\tools\struo\toolchain\bin\x86_64-win64\fpc.exe
```

`bundled` is the normal answer. The licence terms for that compiler are in
[THIRD-PARTY.md](../THIRD-PARTY.md); in short, a binary *you* build with Struo
is yours to licence however you like.

## Where Struo looks

In this order, first hit wins:

| | Where | Reported as |
| --- | --- | --- |
| 1 | `STRUO_FPC` — a path to an `fpc` executable | `explicit` |
| 2 | `STRUO_TOOLCHAIN` — a path to a Free Pascal install root | `explicit` |
| 3 | `toolchain/` beside the `struo` binary | `bundled` |
| 4 | `fpc` on `PATH`, then `C:\FPC`, `C:\lazarus\fpc`, `/usr/bin` | `system` |

An explicit choice beats the bundled toolchain, because someone setting
`STRUO_FPC` is telling Struo something it should not second-guess. Everything
else loses to the bundled one, so a machine with an old Free Pascal lying
around does not quietly change what Struo compiles with.

`struo toolchain` lists every candidate it can see, and warns when the active
one is a `system` compiler — a build there is not necessarily the build a
colleague gets.

## The bundled toolchain reads no configuration

Struo runs a bundled compiler with `-n`, which tells Free Pascal to read no
`fpc.cfg` at all, and supplies every search path itself.

This is not an optimisation; it is what makes a bundled toolchain mean
anything. Free Pascal looks for `fpc.cfg` in the user's home directory and in
`C:\ProgramData` before its own, so a configuration file left behind by some
other Pascal install could otherwise reach into a Struo build and point it at
another installation's units. The failure would look like a compiler bug in
your package. Release archives therefore ship no `fpc.cfg` either.

A `system` compiler keeps its configuration, since the user may have put
something there that Struo cannot know about.

## What is bundled

A release archive carries a curated set of unit packages rather than every
package Free Pascal ships. `googleapi`, `winunits-jedi` and `odata` alone are
42% of a full unit tree, and almost no Pascal package needs them; curating
takes the archive from 69 MB to 27 MB.

These are available to `uses` out of the box:

| Group | Packages |
| --- | --- |
| The language | `rtl`, `rtl-objpas`, `rtl-extra`, `rtl-console`, `rtl-unicode`, `rtl-generics` |
| Free Component Library | `fcl-base`, `fcl-process`, `fcl-json`, `fcl-xml`, `fcl-net`, `fcl-res`, `fcl-registry`, `fcl-extra`, `fcl-stl`, `fcl-fpcunit` |
| Build, compression, crypto | `fpmkunit`, `hash`, `regexpr`, `paszlib`, `zlib`, `openssl` |
| Windows | `winunits-base` |

That covers the RTL, `Classes`, `SysUtils`, `Generics.Collections`, JSON, XML,
sockets, processes, regular expressions, hashing, zlib and OpenSSL bindings.

If your package needs something outside the list — a database client, GTK, the
Google API bindings — install Free Pascal yourself and point Struo at it:

```console
$ set STRUO_TOOLCHAIN=C:\FPC\3.2.2
$ struo toolchain
active  fpc 3.2.2   i386-win32   explicit  C:\FPC\3.2.2\bin\i386-Win32\fpc.exe
```

The archive is built by `packaging/release.ps1`, and `-Full` there produces one
with every package. The curated list lives in that script, next to this table;
change one and change the other.

## Checking the toolchain works

```console
$ struo toolchain --verify
   Verifying fpc 3.2.2 (bundled)
    Finished the toolchain compiles, links and runs
```

This compiles and runs a three-line program that uses a packaged unit. It is
worth more than it looks for a bundled compiler: a shipped toolchain can
arrive truncated by a bad download, or stripped of its assembler by an
over-eager antivirus, and the failure then surfaces as a baffling link error
inside your own package. `--verify` turns that into a plain answer.

`packaging/release.ps1` runs this against the staged archive before zipping
it, so an archive that cannot compile never gets published.

## Building Struo from source

Building Struo itself needs a Free Pascal you installed, because Struo is
written in Pascal and the first binary has to come from somewhere:

```console
$ ./bootstrap/build.ps1          # Windows
$ ./bootstrap/build.sh           # Linux, macOS
```

That produces `bin/struo` with no bundled toolchain, so it falls back to your
system compiler and `struo toolchain` reports `system`. That is expected for a
development build. `packaging/release.ps1` is what turns it into an archive
with a toolchain inside.
