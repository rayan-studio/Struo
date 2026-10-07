# Command reference

```
struo <command> [options] [arguments]
```

Global options, accepted by every command:

| Option | Effect |
| --- | --- |
| `-h`, `--help` | Print help for the command and exit |
| `-V`, `--version` | Print Struo's version and exit |
| `-v`, `--verbose` | Show the compiler invocations Struo runs |
| `-q`, `--quiet` | Print nothing but errors |
| `--color <when>` | `auto` (default), `always`, `never` |
| `--manifest-path <p>` | Use this `Struo.toml` instead of searching upward |

Struo exits `0` on success, `1` on a build or command failure, and `2` when the
command line itself is wrong.

---

## Creating packages

### `struo new <path>`

Create a package in a new directory, with a manifest, a source file, a
`.gitignore`, and a fresh git repository.

| Option | Effect |
| --- | --- |
| `--bin` | Binary package with `src/main.pas` (default) |
| `--lib` | Library package with `src/<name>.pas` |
| `--name <n>` | Package name, when it differs from the directory name |
| `--vcs <v>` | `git` (default) or `none` |

```console
$ struo new hello
    Created binary (application) package `hello`
```

### `struo init`

The same as `new`, but for the current directory. Refuses to overwrite an
existing `Struo.toml`.

---

## Building

### `struo build`

Resolve dependencies, compile them, then compile this package's targets into
`target/<profile>/`.

| Option | Effect |
| --- | --- |
| `--release` | Use the `release` profile |
| `--profile <p>` | Use a named profile |
| `--bin <n>` | Build only this binary |
| `--lib` | Build only the library |
| `--all-targets` | Build binaries, tests and examples |
| `--target <triple>` | Cross-compile |
| `--jobs <n>` | Parallel compile jobs |

### `struo run [-- <args>]`

`build`, then execute the binary. Everything after `--` is passed to the
program, not to Struo.

```console
$ struo run -- --city Brussels
```

Use `--bin <n>` when a package has more than one binary.

### `struo check`

Compile for diagnostics only; skip linking. Faster than `build` when you just
want to know whether the code is valid.

### `struo test`

Build the test targets and run each one. A test target is any `.pas` file in
`tests/`, plus every `[[test]]` in the manifest. A test binary passes when it
exits `0`.

### `struo clean`

Delete `target/`. With `--release` or `--profile <p>`, delete only that
profile's directory.

---

## Dependencies

### `struo add <dep>...`

Add dependencies to `Struo.toml` and update `Struo.lock`. The manifest is
edited surgically: your comments and formatting survive.

| Option | Effect |
| --- | --- |
| `--version <req>` | Pin a SemVer requirement instead of the latest release |
| `--path <p>` | Add a path dependency |
| `--git <url>` | Add a git dependency |
| `--branch`, `--tag`, `--rev` | Pin the git dependency |
| `--dev` | Add under `[dev-dependencies]` |
| `--optional` | Mark the dependency optional |
| `--features <list>` | Comma-separated features to enable |

```console
$ struo add fjson
      Adding fjson v1.2.0 to dependencies

$ struo add fcolor --git https://github.com/x/fcolor --tag v1.0.0
$ struo add mylib --path ../mylib
```

### `struo remove <dep>...`

Drop dependencies from the manifest and the lockfile.

### `struo update [<dep>...]`

Re-resolve dependencies within the requirements in `Struo.toml` and rewrite
`Struo.lock`. With no arguments, updates everything.

| Option | Effect |
| --- | --- |
| `--precise <v>` | Move one dependency to an exact version |
| `--dry-run` | Report what would change, write nothing |

### `struo tree`

Print the resolved dependency graph.

```console
$ struo tree
weather v0.3.1 (C:\dev\weather)
├── fjson v1.2.0
└── fhttp v0.4.2
    └── fjson v1.2.0 (*)
```

---

## Registry

### `struo search <query>`

Search the registry index by name, description and keywords.

### `struo publish`

Package the current directory and upload it. Requires `description` and
`license` in the manifest, a clean working tree, and a version that is not
already published.

| Option | Effect |
| --- | --- |
| `--dry-run` | Build the archive and validate it, upload nothing |
| `--allow-dirty` | Publish with uncommitted changes |

### `struo login` / `struo logout`

Store or remove the registry API token in Struo's config directory.

---

## Diagnostics

### `struo doctor`

Report what Struo detected, which is the first thing to check when a build
behaves unexpectedly.

```console
$ struo doctor
Struo       0.1.0
Compiler    fpc 3.2.2 (C:\FPC\3.2.2\bin\i386-Win32\fpc.exe)
Host        i386-win32
Home        C:\Users\you\.struo
Registry    https://index.struo.dev
```
