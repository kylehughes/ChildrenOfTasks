import ChildrenOfTasks

func invalid() async {
    await withChildren { c in
        let t = Task {
            _ = c.start {
                7
            }
        }
        await t.value
    }
}
