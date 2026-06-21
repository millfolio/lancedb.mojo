"""Round-trip gate for the delete/optimize FFI: add 5 rows, delete two by id,
optimize, and assert count + that the deleted ids no longer surface in search."""

from lancedb import Store
from std.os import getenv


def main() raises:
    var uri = getenv("TMPDIR", "/tmp") + "/lancedb_delete_test.db"
    var dim = 4
    var store = Store(uri, String("vec"), dim)

    # 5 rows, ids 0..4; vector i is the one-hot-ish [i,i,i,i] so search is obvious.
    var ids = List[Int64]()
    var vecs = List[Float32]()
    for i in range(5):
        ids.append(Int64(i))
        for _ in range(dim):
            vecs.append(Float32(i))
    store.add(ids, vecs)
    print("after add, count =", store.count())
    if store.count() != 5:
        raise Error("expected 5 rows after add")

    # Delete ids 1 and 3, then compact.
    var drop = List[Int64]()
    drop.append(Int64(1))
    drop.append(Int64(3))
    store.delete_ids(drop)
    store.optimize()
    print("after delete_ids([1,3]) + optimize, count =", store.count())
    if store.count() != 3:
        raise Error("expected 3 rows after deleting 2")

    # A query near id=3 must NOT return 3 (it's gone); nearest should be 2 or 4.
    var q = List[Float32]()
    for _ in range(dim):
        q.append(Float32(3))
    var res = store.search(q, 3)
    var got = res[0].copy()
    print("search near 3 returned", len(got), "ids:")
    for i in range(len(got)):
        print("  ", got[i])
        if got[i] == Int64(1) or got[i] == Int64(3):
            raise Error("deleted id resurfaced in search: " + String(got[i]))

    print("OK: delete + optimize + search all consistent")
