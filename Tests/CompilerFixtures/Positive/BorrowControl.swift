import ChildrenOfTasks

func helper(_ c: borrowing Children) {
    _ = c.start {
        7
    }
}
func valid() async {
    await withChildren {
        c in helper(c)
    }
}
final class Local {
    var value = 1
}
@MainActor func actorBody() async -> Local {
    let local = Local()

    return await withChildren { c in
        local.value += 1
        let a = c.start {
            @MainActor in local.value
        }

        let n = await a.value()
        precondition(n == 2)

        return local
    }
}
