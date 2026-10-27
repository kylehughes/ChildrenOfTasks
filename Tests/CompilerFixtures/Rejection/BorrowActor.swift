import ChildrenOfTasks

actor Other {
    func spawn(_ c: borrowing Children) {
        _ = c.start {
            7
        }
    }
}
func invalid(_ other: Other) async {
    await withChildren {
        c in await other.spawn(c)
    }
}
