extends RefCounted
class_name LargeRockObstacleManifest

# Canonical transforms are intentionally committed beside the runtime guard.
# They freeze the user-reviewed 2026-08-24 layout independently of scene-editor
# drift and make every rendered large rock addressable by the training exporter.
const SCHEMA_VERSION := "large_rock_obstacle_manifest_v1"
const MANIFEST_ID := "taoyuan_large_rocks_reviewed_2026_08_24"
const EXPECTED_ROCK_COUNT := 32
const COLLECTION_PATHS: Array[String] = [
	"TerrainUpperWalkableRegions/FloatingPlates/Rock3A_Comparison_Set",
	"TerrainUpperWalkableRegions/FloatingPlates/GroundedRockPlate_Comparison_Set",
]

const CANONICAL_LOCAL_TRANSFORMS := {
	"Rock3A_01_BroadAncientRoot": [4.886402, 0, 1.778505, 0, 6.1, 0, -1.778505, 0, 4.886402, -376.82202, 106.86864, -153.82887],
	"Rock3A_02_TallNeedleRoot": [4.026727, 0, -1.003976, 0, 7.6, 0, 1.003976, 0, 4.026727, -30.298012, 222.04218, -314.2568],
	"Rock3A_03_WideMossShelf": [4.067552, 0, 2.641499, 0, 5.35, 0, -2.641499, 0, 4.067552, 284.0095, 111.99838, 170.2163],
	"Rock3A_04_FracturedTwinRibs": [2.489294, 0, -2.669441, 0, 6.8, 0, 2.669441, 0, 2.489294, 111.90617, 164.85033, -356.5587],
	"Rock3A_05_CaveBellyHeavy": [4.406693, 0, 0.61932, 0, 7, 0, -0.61932, 0, 4.406693, -292.88272, 147.60991, 405.18533],
	"Rock3A_06_SlenderSideSpire": [1.77523, 0, 2.840961, 0, 8.2, 0, -2.840961, 0, 1.77523, -286.7837, 190.63986, -1.5943375],
	"Rock3A_07_StackedCliffPlate": [4.458885, 0, -2.370831, 0, 5.9, 0, 2.370831, 0, 4.458885, 266.75693, 203.02338, -283.10394],
	"Rock3A_08_HollowMoonCut": [3.492781, 0, 3.144914, 0, 6.55, 0, -3.144914, 0, 3.492781, 203.01834, 80.397964, 104.36876],
	"Rock3A_09_OverhangWaterGroove": [2.018728, 0, -3.796675, 0, 6.2, 0, 3.796675, 0, 2.018728, 67.39755, 2.5000153, 131.02866],
	"Rock3A_09_OverhangWaterGroove2": [2.018728, 0, -3.796675, 0, 6.2, 0, 3.796675, 0, 2.018728, 8.516472, 42.726646, 119.08272],
	"Rock3A_10_DenseBottomShard": [3.608505, 0, 1.60661, 0, 7.3, 0, -1.60661, 0, 3.608505, -93.88628, 94.519424, -147.9371],
	"Rock3A_11_RoundedGardenTop": [5.409377, 0, -0.664188, 0, 5.1, 0, 0.664188, 0, 5.409377, -185.74391, 11.913132, -33.306313],
	"Rock3A_11_RoundedGardenTop2": [5.409377, 0, -0.664188, 0, 5.1, 0, 0.664188, 0, 5.409377, -175.86871, 203.23679, -152.24266],
	"Rock3A_12_AsymmetricBrokenWing": [1.318551, 0, 3.82935, 0, 6.95, 0, -3.82935, 0, 1.318551, 249.68268, 255.56445, -24.842178],
	"Rock3A_13_LowBroadSanctumBase": [5.505777, 0, 1.475269, 0, 4.6, 0, -1.475269, 0, 5.505777, -230, -4, 45],
	"Rock3A_14_DeepRootOldMountain": [5.052311, 0, -3.6707191, 0, 11.05, 0, 3.6707191, 0, 5.052311, -68.5435, -5.752632, 112.31653],
	"Rock3A_15_SideCaveFang": [2.460221, 0, 2.830161, 0, 7.55, 0, -2.830161, 0, 2.460221, -21.355263, 2.4438934, -170.48863],
	"Rock3A_16_MossyBrokenCrown": [2.985958, 0, -3.821852, 0, 6.15, 0, 3.821852, 0, 2.985958, 152.75237, 201.28337, 246.41367],
	"Rock3A_17_PairedSubRoots": [3.642961, 0, 2.188912, 0, 7.85, 0, -2.188912, 0, 3.642961, -93.00845, 161.0458, 259.94214],
	"Rock3A_18_LightFloatingShard": [2.931108, 0, -1.009261, 0, 4.85, 0, 1.009261, 0, 2.931108, -98.67134, 65.94647, 129.17862],
	"Rock3A_18_LightFloatingShard2": [2.931108, 0, -1.009261, 0, 4.85, 0, 1.009261, 0, 2.931108, 91.885826, 44.2901, 37.313232],
	"Rock3A_19_GrandTerraceRoot": [2.345286, 0, 4.808548, 0, 6.7, 0, -4.808548, 0, 2.345286, 149.95076, -13.655762, 43.66838],
	"Rock3A_20_AncientSplitPeak": [3.5094, 0, -3.050674, 0, 8.35, 0, 3.050674, 0, 3.5094, -218.40262, 200.46605, 147.75645],
	"GroundedPlate_01_BroadLandMass": [7.9130087, 0, -5.5407486, 0, 8.919, 0, 5.5407486, 0, 7.9130087, -460, -24.71473, 280],
	"GroundedPlate_02_CrookedStoneMesa": [4.679112, 0, -2.876554, 0, 6.9, 0, 2.876554, 0, 4.679112, 81.4774, 22.445908, -107.50325],
	"GroundedPlate_02_CrookedStoneMesa2": [6.383241, 0, -3.9241922, 0, 9.412, 0, 3.9241922, 0, 6.383241, 14.14138, -13.826401, -281.45706],
	"GroundedPlate_03_ForkedGroundPillar": [3.653294, 0, 4.266269, 0, 7.4, 0, -4.266269, 0, 3.653294, 150.41829, -35.955658, 250.10446],
	"GroundedPlate_03_ForkedGroundPillar2": [3.653294, 0, 4.266269, 0, 7.4, 0, -4.266269, 0, 3.653294, 152.36841, -1.28479, -43.593002],
	"GroundedPlate_04_WideBridgeSlab": [8.3198185, 0, -8.3198185, 0, 8.862, 0, 8.3198185, 0, 8.3198185, -520, -35.739677, -200],
	"GroundedPlate_05_CaveCutLandRoot": [-3.9745495, 0, 5.826471, 0, 8.389, 0, -5.826471, 0, -3.9745495, 200.49957, -15.891289, -234.32158],
	"GroundedPlate_06_TwistedButtressMesa": [3.5399923, 0, -7.681551, 0, 8.71, 0, 7.681551, 0, 3.5399923, 620, -24.94445, 450],
	"GroundedPlate_07_AncientWallPlate": [8.332239, 0, 3.8147972, 0, 8.122, 0, -3.8147972, 0, 8.332239, -120, -39.053867, 520],
}


static func canonical_transform(rock_name: String) -> Transform3D:
	var raw := CANONICAL_LOCAL_TRANSFORMS.get(rock_name, []) as Array
	if raw.size() != 12:
		return Transform3D.IDENTITY
	return Transform3D(
		Basis(
			Vector3(float(raw[0]), float(raw[1]), float(raw[2])),
			Vector3(float(raw[3]), float(raw[4]), float(raw[5])),
			Vector3(float(raw[6]), float(raw[7]), float(raw[8]))
		),
		Vector3(float(raw[9]), float(raw[10]), float(raw[11]))
	)


static func has_rock(rock_name: String) -> bool:
	return CANONICAL_LOCAL_TRANSFORMS.has(rock_name)


static func rock_names() -> Array:
	return CANONICAL_LOCAL_TRANSFORMS.keys()


static func collection_paths() -> Array[String]:
	return COLLECTION_PATHS.duplicate()


static func manifest_schema_version() -> String:
	return SCHEMA_VERSION


static func manifest_id() -> String:
	return MANIFEST_ID


static func expected_rock_count() -> int:
	return EXPECTED_ROCK_COUNT
