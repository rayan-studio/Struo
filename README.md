# Struo

[![CI](https://github.com/rayan-studio/Struo/actions/workflows/ci.yml/badge.svg)](https://github.com/rayan-studio/Struo/actions/workflows/ci.yml)

**The package manager and build tool for Pascal.**

Struo is to Pascal what Cargo is to Rust: one command to create a project,
build it, run it, test it, and pull in dependencies from a registry.

```console
$ struo new hello
    Created binary (application) package `hello`

$ cd hello && struo run
   Compiling hello v0.1.0 (C:\dev\hello)
    Finished `debug` profile [unoptimized + debuginfo] in 0.41s
     Running `target\debug\hello.exe`
Hello, world!
```

Struo is written in Free Pascal and builds itself. A release ships the Free
Pascal compiler inside it, so there is nothing else to install — unpack one
archive and build.

> **Status: early development.** Everything shown below works, with one
> exception called out where it appears: the package registry is not live, so
> dependencies come from a path or a git url for now. See
> [Roadmap](#roadmap).

## Why

Pascal has excellent compilers and a deep library ecosystem, but no common way
to declare "my project needs these libraries at these versions". Projects ship
hand-written build scripts, vendored source trees, and IDE-specific project
files that break the moment you leave the IDE. Struo fills that gap:

- **A manifest instead of a build script.** `Struo.toml` declares what your
  package *is*; Struo works out the compiler invocation.
- **Reproducible builds.** `Struo.lock` pins the exact resolved versions, so a
  clone of your repo compiles the same code you compiled.
- **Real dependencies.** `struo add fjson` and the unit is on your search path.
- **A conventional layout.** `src/`, `tests/`, `examples/` mean a newcomer can
  navigate any Struo package.

## Installation

Download the archive for your platform, unpack it, and put the `struo` binary
on your `PATH`. **You do not need to install Free Pascal**: the archive carries
a compiler inside it, at 27 MB.

```console
$ struo toolchain
active  fpc 3.2.2   x86_64-win64   bundled   C:\tools\struo\toolchain\bin\x86_64-win64\fpc.exe

$ struo toolchain --verify
   Verifying fpc 3.2.2 (bundled)
    Finished the toolchain compiles, links and runs
```

If you already have a Free Pascal you would rather use, set `STRUO_TOOLCHAIN`
to its install root and Struo will prefer it. See
[the toolchain](docs/toolchain.md) for what is bundled and how Struo chooses.

The bundled compiler is GPL/LGPL licensed and is not Struo's own code; see
[THIRD-PARTY.md](THIRD-PARTY.md). A binary *you* build with Struo is yours to
licence however you like — the Free Pascal runtime carries a linking
exception that says so.

### From source

Building Struo itself needs a Free Pascal you installed, since the first
binary has to come from somewhere:

```console
git clone https://github.com/rayan-studio/Struo.git
cd Struo
./bootstrap/build.ps1      # Windows
./bootstrap/build.sh       # Linux / macOS
```

That produces `bin/struo` with no bundled toolchain, so it uses your system
compiler. `./packaging/release.ps1` is what builds an archive with one inside.

## A tour

Create a package, add a dependency, build it:

```console
$ struo new myapp
$ cd myapp
$ struo add fcolor --git https://github.com/x/fcolor --tag v1.0.0
     Cloning https://github.com/x/fcolor
      Adding fcolor v1.0.0 to dependencies
     Locking 2 package(s) in Struo.lock
$ struo build
   Compiling fcolor v1.0.0
   Compiling myapp v0.1.0 (C:\dev\myapp)
    Finished `debug` profile [unoptimized + debuginfo] in 0.31s
```

> The registry is not live yet, so a dependency needs a `--git` url or a
> `--path`. `struo add fjson` tells you as much and names both forms. Path and
> git dependencies are fully resolved, locked and compiled today.

The package Struo generated for you:

```
myapp/
├── Struo.toml          # the manifest: name, version, dependencies
├── Struo.lock          # generated: exact resolved versions
├── src/
│   └── main.pas        # entry point of a binary package
└── target/             # build output (never commit this)
    ├── debug/
    └── release/
```

And its manifest:

```toml
[package]
name = "myapp"
version = "0.1.0"
edition = "2026"

[dependencies]
fjson = "1.2.0"
```

Full reference: [the manifest format](docs/manifest.md) and
[the command reference](docs/commands.md).

## Commands

| Command | What it does |
| --- | --- |
| `struo new <name>` | Create a new package in a new directory |
| `struo init` | Turn the current directory into a package |
| `struo build` | Compile the package and its dependencies |
| `struo run` | Build, then run the binary |
| `struo test` | Build and run the test targets |
| `struo check` | Compile without producing a final binary |
| `struo clean` | Delete `target/` |
| `struo add <dep>` | Add a dependency to the manifest |
| `struo remove <dep>` | Drop a dependency from the manifest |
| `struo update` | Re-resolve dependencies and refresh the lockfile |
| `struo tree` | Print the dependency graph |
| `struo publish` | Upload the package to the registry |
| `struo toolchain` | Report the Free Pascal toolchain in use |
| `struo doctor` | Report the detected compiler and Struo paths |

Every command takes `--help`.

## Roadmap

- [x] **0.1 — Foundations.** Manifest parsing, target inference from the
      layout, `new`/`init`, `build`/`run`/`check`/`test`/`clean`/`doctor`
      against a real FPC invocation. Struo builds itself.
- [x] **0.2 — Dependencies.** `path` and `git` dependencies, `Struo.lock`,
      SemVer requirements, `add`/`remove`/`update`/`tree`.
- [ ] **0.3 — Registry.** A git-backed index so `struo add fjson` resolves a
      version, plus `struo search` and `struo publish`.
- [x] **0.2.1 — A bundled toolchain.** A release carries Free Pascal inside
      it, run hermetically, so installing Struo installs everything.
- [ ] **0.4 — Polish.** Features and optional dependencies, workspaces,
      incremental rebuilds, cross-compilation, Delphi-compatible output.

## Contributing

Struo builds itself, so the development loop is short:

```console
./bootstrap/build.ps1 && ./bin/struo.exe --version
```

Source layout is documented in [docs/architecture.md](docs/architecture.md).

## License

MIT — see [LICENSE](LICENSE).
