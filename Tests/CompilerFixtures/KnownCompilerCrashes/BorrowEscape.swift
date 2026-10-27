import ChildrenOfTasks

func invalid() async -> () -> Void {
    await withChildren { c in
        {
            _ = c.start {
                7
            }
        }
    }
}
