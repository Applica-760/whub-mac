func reorderedTabs<Element, ID: Equatable>(
    _ tabs: [Element], moving id: ID, before target: ID?, identifiedBy key: KeyPath<Element, ID>
) -> [Element]? {
    guard id != target,
          let source = tabs.firstIndex(where: { $0[keyPath: key] == id }),
          target == nil || tabs.contains(where: { $0[keyPath: key] == target }) else { return nil }
    var result = tabs
    let tab = result.remove(at: source)
    let destination = target.flatMap { target in result.firstIndex { $0[keyPath: key] == target } }
        ?? result.endIndex
    result.insert(tab, at: destination)
    return result
}
