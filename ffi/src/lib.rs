//! C-ABI shim over the `lancedb` crate for the lancedb.mojo Mojo binding.
//!
//! lancedb's API is async (tokio); this exposes a *synchronous* C ABI by blocking
//! each call on a shared multi-thread runtime. Only fixed-width arrays cross the
//! boundary (`i64` ids, `f32` vectors) — the vault layer keeps chunk text/aliases
//! on the Mojo side, so no strings or Arrow types leak through FFI.
//!
//! Table schema is fixed: `id: Int64` + `vector: FixedSizeList<Float32, dim>`.
//! Errors are signalled by a null pointer (handles) or negative return (ops);
//! the last error message is retrievable via `ldb_last_error`.

use std::ffi::{c_char, CStr};
use std::os::raw::c_void;
use std::ptr;
use std::sync::{Arc, OnceLock};

use arrow_array::types::Float32Type;
use arrow_array::{
    Float32Array, Int64Array, RecordBatch, RecordBatchIterator,
};
use arrow_schema::{DataType, Field, Schema};
use futures::TryStreamExt;
use lancedb::query::{ExecutableQuery, QueryBase};
use lancedb::{connect, Connection};
use tokio::runtime::Runtime;

// ── runtime + last-error ──────────────────────────────────────────────────────

fn rt() -> &'static Runtime {
    static RT: OnceLock<Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .expect("tokio runtime")
    })
}

thread_local! {
    static LAST_ERR: std::cell::RefCell<std::ffi::CString> =
        std::cell::RefCell::new(std::ffi::CString::new("").unwrap());
}

fn set_err(msg: String) {
    LAST_ERR.with(|e| {
        *e.borrow_mut() =
            std::ffi::CString::new(msg).unwrap_or_else(|_| std::ffi::CString::new("err").unwrap());
    });
}

/// Pointer to a NUL-terminated message for the most recent failure on this thread.
/// Valid until the next failing call on the same thread; do not free.
#[no_mangle]
pub extern "C" fn ldb_last_error() -> *const c_char {
    LAST_ERR.with(|e| e.borrow().as_ptr())
}

// ── opaque handles ────────────────────────────────────────────────────────────

struct Conn {
    inner: Connection,
}
// A table handle is just a (cloned) connection + name + dim. We resolve the live
// `Table` per op rather than caching it: LanceDB has no usable empty-table state
// (create_empty_table / open_table on a 0-row table panic with div-by-zero), so
// the table only exists once it has data, created lazily on the first `add`.
struct Tbl {
    conn: Connection,
    name: String,
    dim: i32,
}

async fn table_exists(conn: &Connection, name: &str) -> bool {
    conn.table_names()
        .execute()
        .await
        .map(|ns| ns.iter().any(|t| t == name))
        .unwrap_or(false)
}

fn schema(dim: i32) -> Arc<Schema> {
    Arc::new(Schema::new(vec![
        Field::new("id", DataType::Int64, false),
        Field::new(
            "vector",
            DataType::FixedSizeList(Arc::new(Field::new("item", DataType::Float32, true)), dim),
            true,
        ),
    ]))
}

// ── connect / open table ──────────────────────────────────────────────────────

/// Connect to (or create) a LanceDB database at `uri` (a directory path).
/// Returns an opaque `Conn*`, or null on error.
#[no_mangle]
pub extern "C" fn ldb_open(uri: *const c_char) -> *mut c_void {
    if uri.is_null() {
        set_err("ldb_open: null uri".into());
        return ptr::null_mut();
    }
    let uri = match unsafe { CStr::from_ptr(uri) }.to_str() {
        Ok(s) => s.to_owned(),
        Err(_) => {
            set_err("ldb_open: uri not utf-8".into());
            return ptr::null_mut();
        }
    };
    match rt().block_on(async { connect(&uri).execute().await }) {
        Ok(inner) => Box::into_raw(Box::new(Conn { inner })) as *mut c_void,
        Err(e) => {
            set_err(format!("ldb_open: {e}"));
            ptr::null_mut()
        }
    }
}

/// Open table `name` if it exists, else create it empty with the fixed schema for
/// `dim`-element vectors. Returns an opaque `Tbl*`, or null on error.
#[no_mangle]
pub extern "C" fn ldb_table(conn: *mut c_void, name: *const c_char, dim: i32) -> *mut c_void {
    if conn.is_null() || name.is_null() || dim <= 0 {
        set_err("ldb_table: bad args".into());
        return ptr::null_mut();
    }
    let conn = unsafe { &*(conn as *const Conn) };
    let name = match unsafe { CStr::from_ptr(name) }.to_str() {
        Ok(s) => s.to_owned(),
        Err(_) => {
            set_err("ldb_table: name not utf-8".into());
            return ptr::null_mut();
        }
    };
    // No I/O here — the table is created lazily on the first add (see Tbl).
    Box::into_raw(Box::new(Tbl {
        conn: conn.inner.clone(),
        name,
        dim,
    })) as *mut c_void
}

// ── add / count / search ──────────────────────────────────────────────────────

/// Append `n` rows: `ids[n]` and row-major `vecs[n*dim]`. Returns 0 on success,
/// -1 on error.
#[no_mangle]
pub extern "C" fn ldb_add(
    tbl: *mut c_void,
    ids: *const i64,
    vecs: *const f32,
    n: usize,
    dim: usize,
) -> i32 {
    if tbl.is_null() || ids.is_null() || vecs.is_null() || n == 0 {
        set_err("ldb_add: bad args".into());
        return -1;
    }
    let tbl = unsafe { &*(tbl as *const Tbl) };
    if dim as i32 != tbl.dim {
        set_err(format!("ldb_add: dim {} != table dim {}", dim, tbl.dim));
        return -1;
    }
    let ids = unsafe { std::slice::from_raw_parts(ids, n) };
    let vecs = unsafe { std::slice::from_raw_parts(vecs, n * dim) };

    let id_arr = Int64Array::from(ids.to_vec());
    let vec_arr = arrow_array::FixedSizeListArray::from_iter_primitive::<Float32Type, _, _>(
        (0..n).map(|i| Some((0..dim).map(|j| Some(vecs[i * dim + j])).collect::<Vec<_>>())),
        dim as i32,
    );
    let sch = schema(dim as i32);
    let batch = match RecordBatch::try_new(
        sch.clone(),
        vec![Arc::new(id_arr), Arc::new(vec_arr)],
    ) {
        Ok(b) => b,
        Err(e) => {
            set_err(format!("ldb_add: batch: {e}"));
            return -1;
        }
    };
    // lancedb's Table::add / create_table want `Scannable`; a boxed
    // RecordBatchReader qualifies.
    let reader: Box<dyn arrow_array::RecordBatchReader + Send> =
        Box::new(RecordBatchIterator::new(vec![Ok(batch)], sch));
    let res = rt().block_on(async {
        if table_exists(&tbl.conn, &tbl.name).await {
            tbl.conn
                .open_table(&tbl.name)
                .execute()
                .await?
                .add(reader)
                .execute()
                .await
                .map(|_| ())
        } else {
            // First write creates the table WITH data (an empty table panics).
            tbl.conn
                .create_table(&tbl.name, reader)
                .execute()
                .await
                .map(|_| ())
        }
    });
    match res {
        Ok(_) => 0,
        Err(e) => {
            set_err(format!("ldb_add: {e}"));
            -1
        }
    }
}

/// Row count, or -1 on error.
#[no_mangle]
pub extern "C" fn ldb_count(tbl: *mut c_void) -> i64 {
    if tbl.is_null() {
        set_err("ldb_count: null tbl".into());
        return -1;
    }
    let tbl = unsafe { &*(tbl as *const Tbl) };
    let res = rt().block_on(async {
        if !table_exists(&tbl.conn, &tbl.name).await {
            return Ok(0usize);
        }
        tbl.conn
            .open_table(&tbl.name)
            .execute()
            .await?
            .count_rows(None)
            .await
    });
    match res {
        Ok(c) => c as i64,
        Err(e) => {
            set_err(format!("ldb_count: {e}"));
            -1
        }
    }
}

/// k-NN search for `query[dim]`. Writes up to `k` ids/distances into the caller's
/// `out_ids[k]` / `out_dists[k]` and returns the number written, or -1 on error.
#[no_mangle]
pub extern "C" fn ldb_search(
    tbl: *mut c_void,
    query: *const f32,
    dim: usize,
    k: usize,
    out_ids: *mut i64,
    out_dists: *mut f32,
) -> i32 {
    if tbl.is_null() || query.is_null() || out_ids.is_null() || out_dists.is_null() || k == 0 {
        set_err("ldb_search: bad args".into());
        return -1;
    }
    let tbl = unsafe { &*(tbl as *const Tbl) };
    if dim as i32 != tbl.dim {
        set_err(format!("ldb_search: dim {} != table dim {}", dim, tbl.dim));
        return -1;
    }
    let q = unsafe { std::slice::from_raw_parts(query, dim) }.to_vec();
    let out_ids = unsafe { std::slice::from_raw_parts_mut(out_ids, k) };
    let out_dists = unsafe { std::slice::from_raw_parts_mut(out_dists, k) };

    let res: Result<usize, String> = rt().block_on(async {
        if !table_exists(&tbl.conn, &tbl.name).await {
            return Ok(0); // nothing indexed yet
        }
        let table = tbl
            .conn
            .open_table(&tbl.name)
            .execute()
            .await
            .map_err(|e| format!("open_table: {e}"))?;
        let mut stream = table
            .query()
            .nearest_to(q)
            .map_err(|e| format!("nearest_to: {e}"))?
            .limit(k)
            .execute()
            .await
            .map_err(|e| format!("execute: {e}"))?;
        let mut written = 0usize;
        while let Some(batch) = stream
            .try_next()
            .await
            .map_err(|e| format!("stream: {e}"))?
        {
            let ids = batch
                .column_by_name("id")
                .and_then(|c| c.as_any().downcast_ref::<Int64Array>())
                .ok_or_else(|| "search: id column missing".to_string())?;
            let dists = batch
                .column_by_name("_distance")
                .and_then(|c| c.as_any().downcast_ref::<Float32Array>())
                .ok_or_else(|| "search: _distance column missing".to_string())?;
            for i in 0..batch.num_rows() {
                if written >= k {
                    break;
                }
                out_ids[written] = ids.value(i);
                out_dists[written] = dists.value(i);
                written += 1;
            }
        }
        Ok(written)
    });
    match res {
        Ok(w) => w as i32,
        Err(e) => {
            set_err(format!("ldb_search: {e}"));
            -1
        }
    }
}

// ── free ──────────────────────────────────────────────────────────────────────

#[no_mangle]
pub extern "C" fn ldb_table_free(tbl: *mut c_void) {
    if !tbl.is_null() {
        unsafe { drop(Box::from_raw(tbl as *mut Tbl)) };
    }
}

#[no_mangle]
pub extern "C" fn ldb_conn_free(conn: *mut c_void) {
    if !conn.is_null() {
        unsafe { drop(Box::from_raw(conn as *mut Conn)) };
    }
}
