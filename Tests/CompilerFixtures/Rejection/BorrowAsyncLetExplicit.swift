import ChildrenOfTasks

func invalid() async {
    await withChildren { (c: borrowing Children) in
        async let a = c.start {
            7
        }

        _ = await a
    }
}
