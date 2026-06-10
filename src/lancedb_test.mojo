"""Round-trip gate for the lancedb binding: open a temp db, add labelled vectors,
search for one of them, and assert the nearest id is the exact match.

Mirrors zlib.mojo's round-trip test — proves the Rust shim + the OwnedDLHandle
binding actually move vectors through LanceDB and back. Run via `pixi run test`."""

from std.os import getenv
from lancedb import Store


def main() raises:
    var dim = 4
    var uri = getenv("HOME", ".") + "/.cache/lancedb-mojo-test.db"
    print("opening", uri)
    var store = Store(uri, String("vec"), dim)

    # Five 4-d vectors on/near the axes; ids 10..14.
    var ids = List[Int64]()
    var vecs = List[Float32]()
    var rows = List[List[Float32]]()
    rows.append([1.0, 0.0, 0.0, 0.0])
    rows.append([0.0, 1.0, 0.0, 0.0])
    rows.append([0.0, 0.0, 1.0, 0.0])
    rows.append([0.0, 0.0, 0.0, 1.0])
    rows.append([0.9, 0.1, 0.0, 0.0])
    for i in range(len(rows)):
        ids.append(Int64(10 + i))
        for j in range(dim):
            vecs.append(rows[i][j])

    store.add(ids, vecs)
    print("rows in table:", store.count())

    # Query near the 3rd-axis vector (id 12) -> nearest must be 12.
    var q: List[Float32] = [0.05, 0.0, 0.95, 0.0]
    var result = store.search(q, 3)
    var rids = result[0].copy()
    var rdist = result[1].copy()
    print("top-3 ids:", end=" ")
    for i in range(len(rids)):
        print(rids[i], "(d=", rdist[i], ")", end="  ")
    print()

    if len(rids) == 0:
        raise Error("FAIL: search returned no rows")
    if rids[0] != Int64(12):
        raise Error("FAIL: nearest id = " + String(Int(rids[0])) + ", expected 12")
    print("PASS: nearest neighbour is id 12")
