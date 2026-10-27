import ChildrenOfTasks

final class Payload {
    var value = 1
}
func invalid() async {
    await withChildren { (children: borrowing Children) in
        _ = children.start {
            Payload()
        }
    }
}
