# Struo

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

Struo is written in Free Pascal and builds itself. No runtime, no VM — a single
executable next to your compiler.

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

Struo needs [Free Pascal](https://www.freepascal.org/) 3.2.0 or newer on your
`PATH`. Until prebuilt binaries ship, bootstrap it from source:

```console
git clone https://github.com/rayan-studio/Struo.git
cd Struo
./bootstrap/build.ps1      # Windows
./bootstrap/build.sh       # Linux / macOS
```

That produces `bin/struo.exe` (or `bin/struo`). Put it on your `PATH`, then
confirm your toolchain:

```console
$ struo doctor
```

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
- [ ] **0.4 — Polish.** Features and optional dependencies, workspaces,
      incremental rebuilds, prebuilt binaries, Delphi-compatible output.

## Contributing

Struo builds itself, so the development loop is short:

```console
./bootstrap/build.ps1 && ./bin/struo.exe --version
```

Source layout is documented in [docs/architecture.md](docs/architecture.md).

## License

MIT — see [LICENSE](LICENSE).
