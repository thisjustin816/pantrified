extension Array {
    /// Every ordering of the elements, for exhaustive delivery-order tests.
    public var permutations: [[Element]] {
        guard count > 1 else { return [self] }
        return indices.flatMap { index -> [[Element]] in
            var rest = self
            let first = rest.remove(at: index)
            return rest.permutations.map { [first] + $0 }
        }
    }
}
