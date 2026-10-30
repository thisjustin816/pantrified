import Foundation
import Testing
@testable import PantrifiedDomain

@Suite("Bundled classification data")
struct BundledClassificationTests {
    @Test("the data says it is not exhaustive and names its version")
    func declaredLimits() {
        let data = ClassificationDataset.bundled

        #expect(!data.isExhaustive)
        #expect(!data.provenance.version.isEmpty)
    }

    @Test("every trait has been reviewed for every entry, so a new trait cannot pass unreviewed")
    func everyTraitReviewed() {
        let unreviewed = Set(DietaryTrait.allCases).subtracting(ClassificationDataset.bundled.coveredTraits)

        #expect(unreviewed.isEmpty, "Review every bundled entry for \(unreviewed), then add it to coveredTraits")
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

    @Test("every food an entry is made from has its own entry")
    func madeFromResolves() {
        let data = ClassificationDataset.bundled
        for entry in data.entries {
            for source in entry.madeFrom {
                #expect(data.entry(for: source) != nil, "\(entry.name.text) is made from unknown \(source.text)")
            }
        }
    }

    @Test("every food that contains milk, egg, peanut, sesame, wheat or soy is linked to it, so excluding it excludes them",
          arguments: [
              (DietaryTrait.milk, "milk"), (.egg, "egg"), (.peanut, "peanut"), (.sesame, "sesame seed"),
              (.wheat, "wheat"), (.soy, "soybean"),
          ])
    func sourcesAreLinked(trait: DietaryTrait, source: String) throws {
        let data = ClassificationDataset.bundled
        let sourceEntry = try #require(data.entry(for: IngredientName(source)))
        for entry in data.entries where entry.contains.contains(trait) && entry != sourceEntry {
            #expect(data.ingredients(of: entry).contains(sourceEntry), "\(entry.name.text) is not made from \(source)")
        }
    }

    @Test("a food has every trait the foods it is made from have, at least as may-contain")
    func madeFromTraitsCarryOver() {
        let data = ClassificationDataset.bundled
        for entry in data.entries {
            var own = entry.contains.union(entry.mayContain)
            // A slaughter byproduct such as gelatin is made from meat without being meat.
            if own.contains(.slaughterByproduct) { own.insert(.meat) }
            for source in data.ingredients(of: entry) {
                let missing = source.contains.union(source.mayContain).subtracting(own)
                #expect(missing.isEmpty, "\(entry.name.text) lacks \(missing) from \(source.name.text)")
            }
        }
    }

    @Test("lookup is exact: a phrase containing a known food is not that food")
    func exactLookup() {
        #expect(ClassificationDataset.bundled.entry(for: IngredientName("peanut sauce")) == nil)
        #expect(ClassificationDataset.bundled.entry(for: IngredientName("Peanuts"))?.name == IngredientName("peanut"))
    }
}
