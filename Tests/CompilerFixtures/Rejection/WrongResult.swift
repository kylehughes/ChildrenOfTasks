import ChildrenOfTasks

func invalid() async {
    await withChildren { (children: borrowing Children) in
        let child: Child<String, Never> = children.start {
            7
        }

        _ = child
    }
}
