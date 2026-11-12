# layonara_nwn
This is a command-line utility for building the haks and module for Layonara.

## Contents

- [Description](#description)
- [Requirements](#requirements)
- [Installation](#installation)
- [Building the haks](#building-the-haks)
- [Compiling the models (`--compile`)](#compiling-the-models---compile)
- [Tests](#tests)

## Description
layonara_nwn is a utility to provide various functionalities for developing
the NWN World of Layonara. Currently the only functionality is for
building the haks located at https://github.com/layonara/nwn-haks

## Requirements
- [Nim](https://nim-lang.org/install.html) 2.0 or newer (the server build uses 2.2.8)
- [neverwinter.nim](https://github.com/niv/neverwinter.nim) (the library, and
  its `nwn_erf` on the PATH; the server build uses 2.1.2)
- For `--compile` only:
  - [cleanmodels](https://github.com/plenarius/cleanmodels/releases) 4.18.1 or
    newer (the server build pins 4.18.1; older versions are refused); and
  - a full NWN:EE install, for the stock supermodels and skeletons.

## Installation
You can install layonara_nwn through `nimble`:

    nimble install https://github.com/plenarius/layonara_nwn

Or by building from source:

    $ git clone https://github.com/plenarius/layonara_nwn
    $ cd layonara_nwn
    $ nimble install

If `nimble` has been configured correctly, the binary should be available on
your path.

## Building the haks
Run it from the root of an nwn-haks checkout:

    layonara_nwn hak --yes

Every folder that holds files becomes a hak: `l64_` plus its path with `/`
turned into `_` (`parts/male/human` becomes `l64_pm_human.hak`). Dot-folders
and `vendor/` are skipped. The tilesets go into `l64_tiles1` to `l64_tiles6`.
The `.hak` files are written into the current folder, or into `--out-dir DIR`.

## Compiling the models (`--compile`)
With `--compile`, every ASCII `.mdl` is compiled to binary by cleanmodels before
it is packed. The checkout itself is never changed:

- the files are hard-linked into a staging folder (`.hakstage/` in the checkout,
  or `--stage-dir`), one hak at a time, and each ASCII model there is replaced
  by its compiled copy;
- binary `.mdl` and every other file, `.wok` included, are packed exactly as
  they are in the repo (cleanmodels' own `.wok` output is never used);
- supermodels, skeletons and materials that exist in several haks are taken
  from the hak that wins in the module's hak order (every model's winning copy
  is linked into the staging folder's `res/models/` and handed to cleanmodels
  as a supermodel folder). Pass that order with
  `--hak-order`: a `.mod`, nwn-module's `module.ifo.json`, or a text file with
  one hak name a line. Without it the haks count in alphabetical order, which
  can differ from the game's.

The build stops (exit status 1) when a model fails to compile, when a compiled
model is bigger than `--max-file-mb` (default 20, the NWSync limit), or when the
game folder has no real models (a small canary model is compiled first).
Missing-resource warnings don't stop it; they are counted in the summary
(`--verbose` lists them). A failed hak is not written.

Compiled models are kept in a cache (`--cache-dir`, default
`layonara_nwn/cleanmodels` in your user cache folder), so a second build only
compiles the models that changed.

### On Linux

    cd nwn-haks
    layonara_nwn hak --yes --compile --hak-order ../nwn-module/module.ifo.json \
      --game-dir ~/.local/share/Steam/steamapps/common/"Neverwinter Nights"

### On macOS

    cd nwn-haks
    layonara_nwn hak --yes --compile --hak-order ../nwn-module/module.ifo.json \
      --game-dir ~/"Library/Application Support/Steam/steamapps/common/Neverwinter Nights"

### On Windows (PowerShell)

    cd nwn-haks
    layonara_nwn hak --yes --compile --hak-order ..\nwn-module\module.ifo.json `
      --game-dir "C:\Program Files (x86)\Steam\steamapps\common\Neverwinter Nights"

`--game-dir` can be left out when cleanmodels finds the game itself (`NWN_ROOT`,
or the usual Steam and GOG folders). cleanmodels is found through
`--cleanmodels PATH`, then the `CLEANMODELS` environment variable, then the PATH
(`cleanmodels.exe` on Windows); download the zip for your system from its
[releases](https://github.com/plenarius/cleanmodels/releases).

Keep the staging folder on the same drive as the checkout: hard links only work
within one volume, and otherwise every file is copied (slower, and it warns).
`.hakstage/` is removed after a successful build; `--keep-stage` keeps it, with
`res/winners.tsv` listing which copy of each model and material won.

Other options: `--workers N` (cleanmodels workers, default 2). See
`layonara_nwn --help`.

## Tests

    nimble test

The tests build layonara_nwn and a fake cleanmodels (`tests/fake_cleanmodels.nim`)
and run them on a small tree in `tests/work/`; they need no game and no real
cleanmodels. `nwn_erf` is taken from the PATH, or built from the neverwinter
package.
