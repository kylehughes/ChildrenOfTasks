import ChildrenOfTasks

func invalid() async -> () -> Void {
    await withChildren { (c: borrowing Children) in
        {
            _ = c.start {
                7
            }
        }
    }
}
