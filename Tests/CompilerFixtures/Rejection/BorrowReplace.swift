import ChildrenOfTasks

func invalid() async {
    await withChildren { (outer: borrowing Children) in
        await withChildren {
            (inner: borrowing Children) in outer = consume inner
        }
    }
}
