"""Guide prose extraction and provenance checks, without any Wiki requests."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import guide_content
import merge_methods


class GuideContentTests(unittest.TestCase):
    def test_variant_fields_ignore_nested_template_and_link_pipes(self):
        text = "{{Mmgtable|Version=Solo|Location=[[Area|The area]]|Details=Use {{il|Tool}}.}}"
        table = guide_content.guide_tables(text)[0][2]
        self.assertEqual(table["version"], "Solo")
        self.assertEqual(table["location"], "[[Area|The area]]")
        self.assertEqual(guide_content.paragraphs(table["details"]), ["Use Tool."])

    def test_nested_templates_preserve_fairy_ring_code(self):
        text = "==Getting there==\n{{Checklist|* Use fairy ring {{Fairycode|AJR}}.\n* Equip climbing boots before the climb.}}"
        routes = guide_content.travel_paragraphs(text)
        self.assertTrue(any("AJR" in route for route in routes))
        self.assertTrue(any("climbing boots" in route for route in routes))

    def test_travel_keeps_quest_and_item_conditions(self):
        text = "==Getting there==\n* Use [[The Heart teleport]]; requires [[Tales of the God Wars]].\n* Use [[Desert amulet 2]] and walk west from Nardah.\n==History==\nA different destination."
        routes = guide_content.travel_paragraphs(text)
        self.assertIn("requires Tales of the God Wars", routes[0])
        self.assertIn("Desert amulet 2", routes[1])
        self.assertNotIn("A different destination", " ".join(routes))

    def test_unknown_template_does_not_silently_remove_travel_condition(self):
        text = "==Getting there==\n* Use the portal. {{Unknown prerequisite|Quest}}\n* Walk east from the town."
        routes = guide_content.travel_paragraphs(text)
        self.assertEqual(routes, ["Walk east from the town."])

    def test_history_is_never_used_as_a_travel_route(self):
        self.assertEqual(guide_content.travel_paragraphs("The hero teleported away.\n==History==\nA battle."), [])

    def test_floor_number_uses_verified_wiki_convention(self):
        self.assertEqual(guide_content.readable("{{FloorNumber|1}}"), "ground floor")
        self.assertEqual(guide_content.readable("{{FloorNumber|2}}"), "floor 1 above ground")
        self.assertEqual(guide_content.readable("{{FloorNumber|3}}"), "floor 2 above ground")

    def test_shared_procedure_precedes_a_table_final_step(self):
        result = guide_content.source_steps({"details": ["Then fire the urns."], "shared": ["First shape the clay."]})
        self.assertEqual(result, ["First shape the clay.", "Then fire the urns."])

    def test_interlanguage_links_and_table_markup_never_become_instructions(self):
        result = guide_content.paragraphs("Do the activity.\n\n[[pt:Translated page]]\n\n{| class=table\n! Price !! Output\n|}")
        self.assertEqual(result, ["Do the activity."])

    def test_summary_cannot_mix_variant_identity_or_income_revision(self):
        method = {"source": {"title": "Money making guide/Test", "revision": 10}, "variant": "Solo", "instructions": [], "location": {"text": "Unknown"}}
        content = {"guides": {("Money making guide/Test", "group"): {"revision": 10, "instructions": ["Group only."]}}, "locations": {}}
        merge_methods.apply_guide_content(method, content)
        self.assertEqual(method["instructions"], [])
        content["guides"][("Money making guide/Test", "solo")] = {"revision": 11}
        with self.assertRaisesRegex(ValueError, "revisions disagree"):
            merge_methods.apply_guide_content(method, content)

    def test_skill_templates_preserve_numeric_access_requirements(self):
        text = "Requires level {{scm|Archaeology|60}} [[Archaeology]]."
        self.assertEqual(guide_content.readable(text), "Requires level 60 Archaeology.")
        self.assertEqual(guide_content.readable("{{scp|Agility|41}} Agility"), "41 Agility")

    def test_polishing_removes_list_introductions_but_keeps_prior_instructions(self):
        self.assertEqual(guide_content.polish_paragraph("Travel methods include:", travel=True), "")
        self.assertEqual(guide_content.polish_paragraph("Bring 15 buckets. Compost bins can be found at the following locations:"), "Bring 15 buckets.")
        self.assertEqual(guide_content.polish_paragraph("Use any anvil except Ashdale:"), "Use any anvil except Ashdale.")

    def test_polishing_route_fragments_preserves_names_and_conditions(self):
        self.assertEqual(guide_content.polish_paragraph("Using a gnome glider to fly to Lemanto Andra (3) leaves the player very close to the ancient door.", travel=True), "Take a gnome glider to Lemanto Andra (3), then walk to the ancient door.")
        self.assertEqual(guide_content.polish_paragraph("Using a Juju teleport spiritbag to teleport to Papa Mambo", travel=True), "Use a Juju teleport spiritbag to teleport to Papa Mambo.")
        self.assertEqual(guide_content.polish_paragraph("An Archaeology teleport, purchased for 250 chronotes", travel=True), "Use an Archaeology teleport, purchased for 250 chronotes.")
        self.assertEqual(guide_content.polish_paragraph("Using The Heart teleport is fastest; it requires Tales of the God Wars.", travel=True), "Using The Heart teleport is fastest; it requires Tales of the God Wars.")

    def test_area_sections_keep_conditions_and_local_notes_together(self):
        method = {"source": {"title": "Money making guide/Test", "revision": 10},
                  "instructions": [], "location": {"text": "Unknown"}}
        content = {"guides": {("Money making guide/Test", ""): {
            "revision": 10, "instructions": ["Do the activity."], "location": "First Camp / Second Camp",
            "places": ["First Camp", "Second Camp"], "travel": [
                "In Second Camp, walk north to the trees.",
                "A full run visits First Camp and Second Camp."]}},
            "locations": {"First Camp": {"revision": 1, "routes": ["Take the boat after Quest A."]},
                          "Second Camp": {"revision": 2, "routes": ["Use the unlocked lodestone."]}}}
        merge_methods.apply_guide_content(method, content)
        location = method["location"]
        self.assertEqual([s["title"] for s in location["sections"]], ["First Camp", "Second Camp"])
        self.assertEqual(location["sections"][0]["routes"], ["Take the boat after Quest A."])
        self.assertEqual(location["sections"][1]["routes"], ["Use the unlocked lodestone.", "In Second Camp, walk north to the trees."])
        self.assertEqual(location["routes"], ["A full run visits First Camp and Second Camp."])

    def test_jadinko_travel_does_not_mistake_potion_prices_for_directions(self):
        content = merge_methods.load_guide_content()
        guide = content["guides"][("Money making guide/Hunting igneous jadinkos", "")]
        self.assertEqual(guide["location"], "Herblore Habitat / Anachronia")
        self.assertNotIn("value is estimated", " ".join(guide.get("travel", [])))
        self.assertEqual(guide["places"], ["Herblore Habitat", "Anachronia"])

    def test_complete_catalogue_has_summaries_and_pinned_area_sources(self):
        content = merge_methods.load_guide_content()
        self.assertEqual(len(content["guides"]), 676)
        for key, guide in content["guides"].items():
            self.assertTrue(guide["instructions"], key)
            self.assertGreater(guide["revision"], 0)
            self.assertTrue(guide["places"] or guide.get("travel") or guide.get("stationary"), key)
            for name in guide["places"]:
                place = content["locations"][name]
                self.assertGreater(place["revision"], 0)
                self.assertTrue(place["routes"])
            for paragraph in guide["instructions"]:
                self.assertNotRegex(paragraph, r"\{\{|\}\}|\[\[|\]\]|unresolved template|https?://")


if __name__ == "__main__":
    unittest.main()
