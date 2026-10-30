import Foundation

// MARK: Import

public enum ShoppingImportDuplicate: Sendable, Hashable {
    case onList(ShoppingItemID)
    case inPaste
}

public struct ShoppingImportLine: Sendable, Hashable {
    public let name: String
    public let quantity: String?
    public let duplicate: ShoppingImportDuplicate?
    /// Duplicates start excluded; the user can include one to add it anyway.
    public var isIncluded: Bool
}

/// Parses pasted multiline text into lines the user reviews before anything is added.
public enum ShoppingTextImport {
    private static let marker = try! NSRegularExpression(
        pattern: #"^\s*(?:[-*•]\s+|\[[ xX]\]\s*|\d+[.)]\s+)+"#
    )
    private static let amount = try! NSRegularExpression(
        pattern: #"^(\d+(?:[./]\d+)?x?)(?:\s+(lbs?|oz|g|kg|ml|l|gallons?|dozen|cups?|tbsp|tsp|packs?|pkgs?|cans?|bottles?|bags?|boxes|box|jars?))?\s+(\S.*)$"#,
        options: [.caseInsensitive]
    )

    public static func review(_ text: String, against list: ShoppingList) -> [ShoppingImportLine] {
        var seen: Set<IngredientName> = []
        var lines: [ShoppingImportLine] = []

        for raw in text.components(separatedBy: .newlines) {
            let stripped = replacing(marker, in: raw).trimmingCharacters(in: .whitespaces)
            guard !stripped.isEmpty else { continue }
            let (quantity, name) = split(stripped)

            let normalized = IngredientName(name)
            let duplicate: ShoppingImportDuplicate?
            if let existing = list.items.first(where: { !$0.isChecked && $0.normalizedName == normalized }) {
                duplicate = .onList(existing.id)
            } else if seen.contains(normalized) {
                duplicate = .inPaste
            } else {
                duplicate = nil
            }
            seen.insert(normalized)
            lines.append(ShoppingImportLine(
                name: name, quantity: quantity, duplicate: duplicate, isIncluded: duplicate == nil
            ))
        }
        return lines
    }

    private static func replacing(_ regex: NSRegularExpression, in text: String) -> String {
        regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: ""
        )
    }

    private static func split(_ text: String) -> (quantity: String?, name: String) {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = amount.firstMatch(in: text, range: range),
              let number = Range(match.range(at: 1), in: text),
              let rest = Range(match.range(at: 3), in: text) else { return (nil, text) }
        let unit = Range(match.range(at: 2), in: text).map { " " + text[$0] } ?? ""
        return (String(text[number]) + unit, String(text[rest]))
    }
}

extension ShoppingList {
    /// Adds every included line, duplicates among them only because the user chose to include them.
    @discardableResult
    public mutating func add(importing lines: [ShoppingImportLine], at date: Date) throws -> [ShoppingItem] {
        var added: [ShoppingItem] = []
        for line in lines where line.isIncluded {
            if case .added(let item) = try add(
                name: line.name, quantity: line.quantity, at: date, allowDuplicate: line.duplicate != nil
            ) {
                added.append(item)
            }
        }
        return added
    }
}

// MARK: Export

/// One entry in a provider-neutral shopping selection, from the list or from a meal's missing
/// ingredients.
public struct ShoppingExportItem: Sendable, Hashable, Identifiable {
    public let id: UUID
    public var name: String
    public var quantity: String?

    public init(id: UUID = UUID(), name: String, quantity: String? = nil) {
        self.id = id
        self.name = name
        self.quantity = quantity
    }
}

public enum PlainTextShoppingExport {
    /// Newline-separated, quantity first when present, for Copy and the Share Sheet.
    public static func text(for selection: [ShoppingExportItem]) -> String {
        selection
            .map { [$0.quantity, $0.name].compactMap { $0 }.joined(separator: " ") }
            .joined(separator: "\n")
    }
}

public struct ReminderExportPlan: Sendable, Hashable {
    public var toAdd: [ShoppingExportItem]
    /// Exact normalized-name matches among incomplete reminders; skipped unless the user insists.
    public var alreadyOnList: [ShoppingExportItem]

    public func itemsToWrite(addAnyway: Set<UUID>) -> [ShoppingExportItem] {
        toAdd + alreadyOnList.filter { addAnyway.contains($0.id) }
    }
}

public enum ReminderExportPlanner {
    public static func plan(
        _ selection: [ShoppingExportItem],
        incompleteReminderTitles: [String]
    ) -> ReminderExportPlan {
        let existing = Set(incompleteReminderTitles.map(IngredientName.init).filter { !$0.isEmpty })
        var plan = ReminderExportPlan(toAdd: [], alreadyOnList: [])
        for item in selection {
            if existing.contains(IngredientName(item.name)) {
                plan.alreadyOnList.append(item)
            } else {
                plan.toAdd.append(item)
            }
        }
        return plan
    }
}
