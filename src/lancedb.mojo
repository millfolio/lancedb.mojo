"""lancedb — Mojo vector store (add / k-NN search) via a Rust cdylib shim.

Mirrors zlib.mojo's FFI pattern: a single relocatable library
(ffi/src/lib.rs -> $CONDA_PREFIX/lib/liblancedbmojo.dylib, built by ffi/build.sh)
loaded through an `OwnedDLHandle`. The handle is passed as a BORROWED `read`
param to each worker so Mojo's ASAP destruction can't `dlclose` the library
mid-call (the flare gotcha) — even though `Store` also owns it as a field, the
borrow keeps it pinned across the C call.

The store holds one table with a fixed schema: `id: Int64` +
`vector: FixedSizeList<Float32, dim>`. Chunk text/aliases live on the caller's
side (headgate's vault index) — only ids + vectors ever cross FFI.

Headline use: headgate's `search(query, k)` over the personal-data vault.
"""

from std.os import getenv
from std.ffi import OwnedDLHandle, c_int, c_char


def _find_lib() -> String:
    """Path to liblancedbmojo.dylib: `$CONDA_PREFIX/lib` (built by ffi/build.sh),
    else `build/` for a bare checkout. Mirrors zlib.mojo._find_lib."""
    var ext = String("dylib")  # macOS cdylib; ffi/build.sh emits .so on Linux
    var prefix = getenv("CONDA_PREFIX", "")
    if prefix == "":
        return String("build/liblancedbmojo.") + ext
    return prefix + "/lib/liblancedbmojo." + ext


def _cstr(s: String) -> List[UInt8]:
    """A NUL-terminated byte buffer for `s`, to pass as a C `const char*`."""
    var b = List[UInt8]()
    var src = s.as_bytes()
    for i in range(len(src)):
        b.append(src[i])
    b.append(0)
    return b^


def _last_error(read lib: OwnedDLHandle) -> String:
    """Read the shim's thread-local last-error C string (for diagnostics)."""
    var func = lib.get_function[
        def () thin abi("C") -> UnsafePointer[UInt8, MutAnyOrigin]
    ]("ldb_last_error")
    var p = func()              # always a valid CString ptr (never null)
    var out = String("")
    var i = 0
    while p[i] != 0 and i < 4096:
        out += chr(Int(p[i]))
        i += 1
    return out^


struct Store(Movable):
    """An open LanceDB table of `dim`-element float vectors, keyed by Int64 id."""
    var lib: OwnedDLHandle
    var conn: Int    # *mut c_void
    var table: Int   # *mut c_void
    var dim: Int

    def __init__(out self, uri: String, table: String, dim: Int) raises:
        """Open (or create) the database at `uri` and the table `table` with the
        fixed schema for `dim`-wide vectors."""
        self.lib = OwnedDLHandle(_find_lib())
        self.dim = dim

        var uri_c = _cstr(uri)
        var open_fn = self.lib.get_function[
            def (Int) thin abi("C") -> Int
        ]("ldb_open")
        self.conn = open_fn(Int(uri_c.unsafe_ptr()))
        _ = uri_c^   # keep the buffer mapped across the C call (ASAP-destruction)
        if self.conn == 0:
            self.table = 0
            raise Error("lancedb.open: " + _last_error(self.lib))

        var name_c = _cstr(table)
        var tbl_fn = self.lib.get_function[
            def (Int, Int, c_int) thin abi("C") -> Int
        ]("ldb_table")
        self.table = tbl_fn(self.conn, Int(name_c.unsafe_ptr()), c_int(dim))
        _ = name_c^  # keep the buffer mapped across the C call
        if self.table == 0:
            raise Error("lancedb.table: " + _last_error(self.lib))

    def __del__(deinit self):
        # Free the LanceDB handles while `self.lib` is still mapped (fields are
        # destroyed after __del__ returns, so the binding stays valid here).
        if self.table != 0:
            var f = self.lib.get_function[
                def (Int) thin abi("C") -> None
            ]("ldb_table_free")
            f(self.table)
        if self.conn != 0:
            var f = self.lib.get_function[
                def (Int) thin abi("C") -> None
            ]("ldb_conn_free")
            f(self.conn)

    def add(self, ids: List[Int64], vectors: List[Float32]) raises:
        """Append rows: `ids[n]` and row-major `vectors[n*dim]`."""
        var n = len(ids)
        if n == 0:
            return
        if len(vectors) != n * self.dim:
            raise Error(
                "lancedb.add: vectors length " + String(len(vectors))
                + " != n*dim (" + String(n) + "*" + String(self.dim) + ")"
            )
        _add(self.lib, self.table, ids, vectors, n, self.dim)

    def delete(self, predicate: String) raises:
        """Delete rows matching a SQL `predicate` over the table columns, e.g.
        `id >= 10 AND id < 20`. Tombstones the rows; call `optimize()` after a
        batch of deletes to reclaim space. A missing table is a no-op."""
        var pred_c = _cstr(predicate)
        var f = self.lib.get_function[
            def (Int, Int) thin abi("C") -> c_int
        ]("ldb_delete")
        var rc = f(self.table, Int(pred_c.unsafe_ptr()))
        _ = pred_c^  # keep the buffer mapped across the C call
        if Int(rc) != 0:
            raise Error("lancedb.delete: " + _last_error(self.lib))

    def delete_ids(self, ids: List[Int64]) raises:
        """Delete the rows with these ids (builds an `id IN (...)` predicate).
        Empty list is a no-op. Used to drop a file's chunks on re-index."""
        if len(ids) == 0:
            return
        var pred = String("id IN (")
        for i in range(len(ids)):
            if i > 0:
                pred += ","
            pred += String(ids[i])
        pred += ")"
        self.delete(pred)

    def optimize(self) raises:
        """Compact fragments + purge tombstoned rows. Run after a batch of
        deletes so storage/scan cost don't grow across re-index cycles."""
        var f = self.lib.get_function[
            def (Int) thin abi("C") -> c_int
        ]("ldb_optimize")
        if Int(f(self.table)) != 0:
            raise Error("lancedb.optimize: " + _last_error(self.lib))

    def create_index(self) raises:
        """Build an ANN index on the vector column (auto type) for search at
        scale. May error when there are too few rows to train an IVF index —
        callers can catch that and stay brute-force until the vault grows."""
        var f = self.lib.get_function[
            def (Int) thin abi("C") -> c_int
        ]("ldb_create_index")
        if Int(f(self.table)) != 0:
            raise Error("lancedb.create_index: " + _last_error(self.lib))

    def count(self) raises -> Int:
        """Number of rows in the table."""
        var func = self.lib.get_function[
            def (Int) thin abi("C") -> Int64
        ]("ldb_count")
        var c = Int(func(self.table))
        if c < 0:
            raise Error("lancedb.count: " + _last_error(self.lib))
        return c

    def search(
        self, query: List[Float32], k: Int
    ) raises -> Tuple[List[Int64], List[Float32]]:
        """k-NN search; returns (ids, distances), nearest first, length <= k."""
        if len(query) != self.dim:
            raise Error(
                "lancedb.search: query length " + String(len(query))
                + " != dim " + String(self.dim)
            )
        return _search(self.lib, self.table, query, self.dim, k)


# ── borrowed-handle workers (lib stays mapped across the C call) ───────────────

def _add(
    read lib: OwnedDLHandle,
    table: Int,
    ids: List[Int64],
    vectors: List[Float32],
    n: Int,
    dim: Int,
) raises:
    var func = lib.get_function[
        def (Int, Int, Int, Int, Int) thin abi("C") -> c_int
    ]("ldb_add")
    var rc = Int(func(
        table, Int(ids.unsafe_ptr()), Int(vectors.unsafe_ptr()), n, dim
    ))
    if rc != 0:
        raise Error("lancedb.add: " + _last_error(lib))


def _search(
    read lib: OwnedDLHandle,
    table: Int,
    query: List[Float32],
    dim: Int,
    k: Int,
) raises -> Tuple[List[Int64], List[Float32]]:
    var func = lib.get_function[
        def (Int, Int, Int, Int, Int, Int) thin abi("C") -> c_int
    ]("ldb_search")

    var out_ids = List[Int64](capacity=k)
    out_ids.resize(k, 0)
    var out_dists = List[Float32](capacity=k)
    out_dists.resize(k, 0.0)

    var got = Int(func(
        table, Int(query.unsafe_ptr()), dim, k,
        Int(out_ids.unsafe_ptr()), Int(out_dists.unsafe_ptr()),
    ))
    if got < 0:
        raise Error("lancedb.search: " + _last_error(lib))

    var ids = List[Int64]()
    var dists = List[Float32]()
    for i in range(got):
        ids.append(out_ids[i])
        dists.append(out_dists[i])
    return (ids^, dists^)
