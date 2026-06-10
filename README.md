# lancedb.mojo

> Part of [**millrace**](https://millrace.me) — local-first AI on Apple Silicon.

A small **Mojo binding for [LanceDB](https://lancedb.com)** — open a local
vector table, add `(id, vector)` rows, and run k-NN search — over a thin **Rust
cdylib** that wraps the `lancedb` crate behind a C ABI. It's the on-device vector
store for [headgate](https://github.com/millrace/headgate)'s **vault search**:
the user's files are chunked, embedded locally, and indexed here so an
open-ended question ("when do I renew my insurance?") can find the right passages
— without any data leaving the machine.

## Design

LanceDB is Rust and its API is async (tokio). This repo exposes it to Mojo the
same way [zlib.mojo](https://github.com/millrace/zlib.mojo) and
[flare](https://github.com/millrace/flare) reach C libraries:

- **`ffi/`** — a Rust `cdylib` (`ffi/src/lib.rs`) that re-exports a handful of
  `extern "C"` functions (`ldb_open`, `ldb_table`, `ldb_add`, `ldb_count`,
  `ldb_search`, …). Each one blocks on a shared tokio runtime, so the boundary is
  **synchronous**. Only fixed-width arrays cross it — `i64` ids and `f32`
  vectors — so no Arrow types or strings leak through FFI. `ffi/build.sh`
  compiles it to `$CONDA_PREFIX/lib/liblancedbmojo.dylib`.
- **`src/lancedb.mojo`** — the Mojo `Store` type, loaded through an
  `OwnedDLHandle`. The handle is passed as a **borrowed `read` param** to every
  worker so Mojo's ASAP destruction can't `dlclose` the library mid-call (the
  flare gotcha).

The table schema is fixed: `id: Int64` + `vector: FixedSizeList<Float32, dim>`.
Chunk text and file aliases stay on the caller's side (headgate's vault index);
LanceDB only does the vector part.

## Prerequisites

- Apple Silicon Mac.
- [pixi](https://pixi.sh) — pins the org nightly Mojo (matches headgate/flare).
- [Rust](https://rustup.rs) (`cargo` on PATH) — to build the FFI shim. The first
  build pulls `lancedb` + `arrow`, so it's slow; later builds are cached.

## Use

```sh
pixi run ffi     # build liblancedbmojo.dylib (cargo release)
pixi run test    # round-trip: add 5 vectors, search, assert nearest id
```

Consume it like zlib.mojo — `-I ../lancedb.mojo/src` and the built dylib (no link
flags; it's dlopened at runtime):

```mojo
from lancedb import Store

def main() raises:
    var store = Store("/path/to/vault.db", "chunks", 768)
    store.add(ids, vectors)                 # ids: List[Int64], vectors: row-major List[Float32]
    var hits = store.search(query, 8)       # -> (List[Int64], List[Float32])
    var ids = hits[0]
    var distances = hits[1]
```

## API

| function | signature | notes |
|---|---|---|
| `Store(uri, table, dim)` | open/create the db + table | fixed `id`/`vector` schema |
| `add(ids, vectors)` | `List[Int64]`, row-major `List[Float32]` | `len(vectors) == len(ids) * dim` |
| `count()` | `-> Int` | rows in the table |
| `search(query, k)` | `List[Float32], Int -> (List[Int64], List[Float32])` | nearest first, length ≤ k |
