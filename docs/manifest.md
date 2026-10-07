# The `Struo.toml` manifest

Every Struo package has a `Struo.toml` at its root. It is
[TOML](https://toml.io/), and it declares what the package *is* — Struo derives
the compiler invocation from it.

Struo parses a deliberate subset of TOML: comments, bare and quoted keys,
dotted keys, tables, arrays of tables, strings, integers, floats, booleans,
arrays and inline tables. Dates and multi-line strings are not accepted.

## `[package]`

The only required section.

```toml
[package]
name = "myapp"              # required
version = "0.1.0"           # required, SemVer
edition = "2026"            # optional, defaults to "2026"
authors = ["Ada <ada@example.com>"]
description = "A short, one-line summary."
license = "MIT"
repository = "https://github.com/me/myapp"
homepage = "https://myapp.dev"
keywords = ["cli", "json"]
readme = "README.md"
```

| Field | Type | Notes |
| --- | --- | --- |
| `name` | string | Required. Lowercase letters, digits, `-` and `_`; must start with a letter. This is also the default unit/binary name. |
| `version` | string | Required. `MAJOR.MINOR.PATCH` with optional `-prerelease` and `+build`. |
| `edition` | string | Language/behaviour baseline. Currently only `"2026"`. |
| `authors` | array of strings | Informational. |
| `description` | string | Required to `struo publish`. |
| `license` | string | SPDX identifier. Required to `struo publish`. |
| `repository`, `homepage`, `readme` | string | Informational. |
| `keywords` | array of strings | Up to 5, used by `struo search`. |

## Targets

A package produces a library, one or more binaries, or both. Struo infers
targets from the directory layout, so most packages declare none of this.

| Path | Inferred target |
| --- | --- |
| `src/<name>.pas` | the library unit |
| `src/main.pas` | a binary named after the package |
| `src/bin/<n>.pas` | an extra binary named `<n>` |
| `tests/*.pas` | one test target per file |
| `examples/*.pas` | one example target per file |

Override with an explicit declaration:

```toml
[lib]
name = "myapp"              # unit name; defaults to package name
path = "src/myapp.pas"

[[bin]]
name = "myapp"
path = "src/main.pas"

[[bin]]
name = "myapp-admin"
path = "src/bin/admin.pas"
```

`[lib]` is a table (at most one library per package); `[[bin]]`, `[[test]]`
and `[[example]]` are arrays of tables.

## `[dependencies]`

Three kinds of dependency, each written as a value under the dependency's name.

```toml
[dependencies]
# 1. Registry — a SemVer requirement
fjson = "1.2.0"
fhttp = { version = "^0.4", optional = true }

# 2. Path — another package on disk, resolved relative to this manifest
mylib = { path = "../mylib" }

# 3. Git — a repository, pinned by branch, tag or revision
fparse = { git = "https://github.com/x/fparse", tag = "v2.1.0" }
fcrypt = { git = "https://github.com/x/fcrypt", rev = "a1b2c3d" }
```

A bare string is shorthand for `{ version = "<string>" }`.

| Key | Type | Notes |
| --- | --- | --- |
| `version` | string | SemVer requirement. See below. |
| `path` | string | Relative path to a directory containing a `Struo.toml`. |
| `git` | string | Clone URL. Combine with exactly one of `branch`, `tag`, `rev`. |
| `optional` | boolean | Only built when enabled by a feature. |
| `default-features` | boolean | Defaults to `true`. |
| `features` | array of strings | Features to enable on the dependency. |

`[dev-dependencies]` uses the same syntax and applies to tests and examples
only. `[build-dependencies]` applies to build scripts.

### Version requirements

| Requirement | Matches |
| --- | --- |
| `"1.2.3"` | `>=1.2.3, <2.0.0` (caret is implied, as in Cargo) |
| `"^1.2.3"` | `>=1.2.3, <2.0.0` |
| `"~1.2.3"` | `>=1.2.3, <1.3.0` |
| `"1.2.*"` | `>=1.2.0, <1.3.0` |
| `">=1.2, <1.5"` | the intersection of both bounds |
| `"*"` | any version |

A `0.x` version treats the minor as breaking: `"0.4.1"` means
`>=0.4.1, <0.5.0`.

## `[build]`

Compiler settings that apply to every profile.

```toml
[build]
mode = "objfpc"             # objfpc | delphi | fpc | macpas
target = "x86_64-win64"     # defaults to the host triple
include = ["include"]        # extra -Fi include paths
units = ["vendor/units"]     # extra -Fu unit search paths
libraries = ["vendor/lib"]   # extra -Fl library paths
defines = ["USE_SSL"]        # -d symbols
flags = ["-vh"]              # raw flags passed through verbatim
```

## `[profile.*]`

`debug` is used by `struo build`; `release` by `struo build --release`.

```toml
[profile.debug]
optimize = 0                # -O0..-O4
debug = true                # -g -gl
checks = true               # range/overflow/IO checks: -Cr -Co -Ci
warnings = "all"            # none | default | all | error

[profile.release]
optimize = 3
debug = false
checks = false
strip = true                # -Xs
smart-link = true           # -XX -CX
```

Defaults match the table above, so an empty manifest still gives you a
debuggable debug build and a fast release build.

## `[features]`

```toml
[features]
default = ["json"]
json = ["dep:fjson"]
tls = ["dep:fhttp", "fhttp/openssl"]
```

A feature maps to a list of other features, `dep:<name>` to enable an optional
dependency, or `<dep>/<feature>` to enable a feature on a dependency.

## Full example

```toml
[package]
name = "weather"
version = "0.3.1"
edition = "2026"
authors = ["Rayan <rayan@example.com>"]
description = "Fetch and render weather forecasts in the terminal."
license = "MIT"
repository = "https://github.com/rayan-studio/weather"
keywords = ["cli", "weather", "http"]

[[bin]]
name = "weather"
path = "src/main.pas"

[lib]
name = "weather"
path = "src/weather.pas"

[dependencies]
fjson = "1.2.0"
fhttp = { version = "^0.4", features = ["tls"] }
fcolor = { git = "https://github.com/x/fcolor", tag = "v1.0.0" }

[dev-dependencies]
fptest = "0.3"

[build]
mode = "objfpc"
defines = ["USE_UNICODE"]

[profile.release]
optimize = 3
strip = true
