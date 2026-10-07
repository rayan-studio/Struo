# Third-party software in a Struo release

Struo itself is MIT licensed; see [LICENSE](LICENSE).

A Struo **release archive** also contains a Free Pascal installation, under
`toolchain/`, so that `struo build` works without a separate compiler install.
That software is not Struo's and is not MIT licensed. This file says what it
is and under what terms you have it.

If you are reading this in the Struo **source repository**, no third-party
software is present here: the repository contains only Struo's own code.

## Free Pascal

- **What:** the Free Pascal compiler, its assembler and linker, its runtime
  library and the Free Component Library units, as shipped by the Free Pascal
  project.
- **Upstream:** <https://www.freepascal.org/>
- **Source:** <https://gitlab.com/freepascal.org/fpc/source> — the release
  tagged with the version `struo toolchain` reports.

Free Pascal is distributed under two different licences, and which one applies
depends on which part you mean.

### The compiler and the tools — GPL v2

`toolchain/bin/` holds the compiler driver (`fpc`), the code generator
(`ppc386`, `ppcx64` or similar) and the binary utilities. These are licensed
under the **GNU General Public License, version 2**, as published by the Free
Software Foundation.

Bundling them beside Struo in one archive is distribution of an aggregate: the
GPL applies to those files and does not extend to Struo's own MIT-licensed
code. Your obligations when you redistribute a Struo release archive are the
GPL's: pass on the licence text and make the corresponding source available,
which the upstream link above satisfies.

### The runtime and the units — LGPL v2 with a linking exception

`toolchain/units/` holds the runtime library and the Free Component Library.
These are licensed under the **GNU Lesser General Public License, version 2**,
with the following modification, which the Free Pascal project states as:

> As a special exception, the copyright holders of this library give you
> permission to link this library with independent modules to produce an
> executable, regardless of the license terms of these independent modules,
> and to copy and distribute the resulting executable under terms of your
> choice, provided that you also meet, for each linked independent module, the
> terms and conditions of the license of that module.

This is the clause that matters to anyone shipping a program built with Struo.
Because of it, **a binary you compile with Struo may be released under any
licence you choose**, including a proprietary one, even though it links the
Free Pascal runtime. You do not inherit the LGPL by compiling with Free
Pascal, and Struo changes nothing about that.

### Licence texts

The full licence texts travel with the toolchain as the Free Pascal project
ships them. They are also at:

- GPL v2 — <https://www.gnu.org/licenses/old-licenses/gpl-2.0.html>
- LGPL v2 — <https://www.gnu.org/licenses/old-licenses/lgpl-2.0.html>

## What is not bundled

`git` is not included. Struo shells out to it for git dependencies, and uses
whichever git is on your `PATH`, under that installation's own terms.

## Checking what you have

```console
$ struo toolchain
active  fpc 3.2.2   x86_64-win64   bundled   ...\toolchain\bin\x86_64-win64\fpc.exe
```

`bundled` means the compiler came from the Struo archive and this file applies.
`system` means Struo found a Free Pascal you installed yourself, and its own
terms apply instead.
