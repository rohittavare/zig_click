# `zig_click`
---
a CLI builder and parser to streamline the design & creation of CLI tools written in Zig. Designed to expose a functional-style interface, and leverage Zig features to validate as much of the CLI design as possible at compile time. If you're CLI builds, it should run.

Inspired by Python's `click` library
---
This repo is a work in progress. Several files won't compile and the build script is broken. However, the following is implemented so far:
- utilities for manipulating data structures at compile-time
- parsing & validation of CLI option declarations
- tokenizer interface to ingest inputs from CLI args or string
- parsing primitive data types from strings
- unittests for all of the above

