import ChildrenOfTasks

func take(_ children: consuming Children) {
}
func invalid() async {
    await withChildren {
        (children: borrowing Children) in take(consume children)
    }
}
