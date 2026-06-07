# src

This directory is reserved for the C implementation of the compiler.

The plan is to move the compiler frontend/backend from the Ruby files in
`legacy/` into C sources here, while keeping the Ruby version available as
the legacy reference and regression oracle.
