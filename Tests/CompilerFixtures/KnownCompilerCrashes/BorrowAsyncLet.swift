import ChildrenOfTasks

func invalid() async {
    await withChildren { c in
        async let a = c.start {
            7
        }
        _ = await a
    }
}
