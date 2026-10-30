import Foundation
import Testing
@testable import PantrifiedDomain

@Suite("Bundled classification data")
struct BundledClassificationTests {
    @Test("the data says it is not exhaustive and covers every trait")
    func declaredLimits() {
        let data = ClassificationDataset.bundled

        #expect(!data.isExhaustive)
        #expect(data.coveredTraits == Set(DietaryTrait.allCases))
        #expect(!data.provenance.version.isEmpty)
    }

    @Test("no entry both contains and may contain the same trait")
    func consistentEntries() {
        for entry in ClassificationDataset.bundled.entries {
            #expect(entry.contains.isDisjoint(with: entry.mayContain), "\(entry.name.text)")
        }
    }

    @Test("wheat always comes with gluten")
    func wheatImpliesGluten() {
        for entry in ClassificationDataset.bundled.entries where entry.contains.contains(.wheat) {
            #expect(entry.contains.contains(.gluten), "\(entry.name.text)")
        }
        for entry in ClassificationDataset.bundled.entries where entry.mayContain.contains(.wheat) {
            #expect(entry.contains.contains(.gluten) || entry.mayContain.contains(.gluten), "\(entry.name.text)")
        }
    }

    @Test("lookup is exact: a phrase containing a known food is not that food")
    func exactLookup() {
        #expect(ClassificationDataset.bundled.entry(for: IngredientName("peanut sauce")) == nil)
        #expect(ClassificationDataset.bundled.entry(for: IngredientName("Peanuts"))?.name == IngredientName("peanut"))
    }
}
