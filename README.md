# layonara_nwn
This is a command-line utility for building the haks and module for Layonara.

## Contents

- [Description](#description)
- [Requirements](#requirements)
- [Installation](#installation)

## Description
layonara_nwn is a utility to provide various functionalities for developing
the NWN World of Layonara. Currently the only functionality is for
building the haks located at https://github.com/plenarius/layo-haks

## Requirements
- [nim](https://github.com/dom96/choosenim) >= 0.20.2
- [neverwinter.nim](https://github.com/niv/neverwinter.nim) >= 1.2.7

## Installation
You can install layonara_nwn through `nimble`:

    nimble install https://github.com/plenarius/layonara_nwn

Or by building from source:

    $ git clone https://github.com/plenarius/layonara_nwn
    $ cd layonara_nwn
    $ nimble install

If `nimble` has been configured correctly, the binary should be available on
your path.
