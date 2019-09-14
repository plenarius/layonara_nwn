# Package

version       = "0.1.0"
author        = "James Greenhalgh"
description   = "Various Layonara related functions for NWN Development"
license       = "MIT"

srcDir        = "src"
bin           = @["layonara_nwn"]

# Dependencies
requires "nim >= 0.20.2"
requires "neverwinter >= 1.2.7"
requires "glob >= 0.9.0"
requires "docopt >= 0.1.0"
