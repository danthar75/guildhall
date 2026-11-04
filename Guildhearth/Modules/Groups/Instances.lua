local ADDON, ns = ...

-- Classic Era instances for the group finder: one entry per dungeon wing, one per raid.
--
-- Source: wago.tools DB2 exports for build 1.15.9.70576 (wow_classic_era), fetched 2026-11-04:
--   https://wago.tools/db2/DungeonEncounter/csv?build=1.15.9.70576  (encounter ids, the ENCOUNTER_END id)
--   https://wago.tools/db2/Map/csv?build=1.15.9.70576               (instanceId = Map ID, GetInstanceInfo return 8)
-- The Era build also carries Season of Discovery encounters. Where a map has several sets,
-- the Era 5-player set (DifficultyID 201) is used: BFD, Gnomeregan and Sunken Temple.
-- BFD also has a second 5-player set (DifficultyID 1, 2910-2916). Which one fires in game is not
-- known yet, so it is listed as `alias` (with `aliasFinal`); ByEncounter treats it like bosses/final.
-- Gnomeregan's DifficultyID 198 set and Sunken Temple's 215 set are the SoD 10- and 20-player
-- raid versions, and are deliberately not aliased.
-- Wings of one instance share its instanceId; the encounter tells the wings apart.
-- Which wing a rare or summoned boss belongs to (Strat, Dire Maul) is from game knowledge.
--
-- Entry: { key, name, short, kind = "dungeon"|"raid", size, instanceId, bosses = {...}, final, tier,
--          alias = {...}?, aliasFinal? }
-- tier orders raids in the picker (release order). Names are plain ASCII.
local Instances = {}
ns.Instances = Instances

local function dungeon(key, name, short, instanceId, bosses, final, size, alias, aliasFinal)
  return { key = key, name = name, short = short, kind = "dungeon", size = size or 5,
    instanceId = instanceId, bosses = bosses, final = final, alias = alias, aliasFinal = aliasFinal }
end

local function raid(key, name, short, instanceId, size, tier, bosses, final)
  return { key = key, name = name, short = short, kind = "raid", size = size,
    instanceId = instanceId, bosses = bosses, final = final, tier = tier }
end

Instances.LIST = {
  dungeon("rfc", "Ragefire Chasm", "RFC", 389, { 2732, 2733, 2734, 2735 }, 2733),
  dungeon("wc", "Wailing Caverns", "WC", 43, { 585, 586, 587, 588, 589, 590, 591, 592 }, 592),
  dungeon("deadmines", "The Deadmines", "VC", 36, { 2741, 2742, 2743, 2744, 2745, 2746, 2747 }, 2747),
  dungeon("sfk", "Shadowfang Keep", "SFK", 33, { 2748, 2749, 2750, 2751, 2752, 2753, 2754, 2755 }, 2755),
  dungeon("bfd", "Blackfathom Deeps", "BFD", 48, { 2761, 2762, 2763, 2764, 2765, 2766, 2767 }, 2767, nil,
    { 2910, 2911, 2912, 2913, 2914, 2915, 2916 }, 2910),
  dungeon("stocks", "The Stockade", "Stocks", 34, { 2756, 2757, 2758, 2759, 2760 }, 2760),
  dungeon("gnomer", "Gnomeregan", "Gnomer", 90, { 2768, 2769, 2770, 2771, 2772 }, 2772),
  dungeon("rfk", "Razorfen Kraul", "RFK", 47, { 2773, 2774, 2775, 2776, 2777, 2778 }, 2778),
  dungeon("sm_gy", "Scarlet Monastery (Graveyard)", "SM GY", 189, { 444, 2779 }, 2779),
  dungeon("sm_lib", "Scarlet Monastery (Library)", "SM Lib", 189, { 446, 447 }, 447),
  dungeon("sm_arm", "Scarlet Monastery (Armory)", "SM Arm", 189, { 448 }, 448),
  dungeon("sm_cath", "Scarlet Monastery (Cathedral)", "SM Cath", 189, { 449, 450 }, 450),
  dungeon("rfd", "Razorfen Downs", "RFD", 129, { 2780, 2781, 2782, 2783, 2784, 2785 }, 2785),
  dungeon("ulda", "Uldaman", "Ulda", 70, { 547, 548, 549, 1887, 551, 552, 553, 554 }, 554),
  dungeon("zf", "Zul'Farrak", "ZF", 209, { 593, 594, 595, 596, 597, 598, 599, 600 }, 600),
  dungeon("mara", "Maraudon", "Mara", 349, { 422, 423, 424, 425, 426, 427, 428, 429 }, 429),
  dungeon("st", "Sunken Temple", "ST", 109, { 2814, 486, 487, 488, 490, 491, 492, 493 }, 493),
  dungeon("brd", "Blackrock Depths", "BRD", 230, { 227, 228, 229, 230, 231, 232, 233, 234, 235, 236, 237,
    238, 239, 240, 241, 242, 243, 244, 2789, 2790, 2791 }, 2790),
  dungeon("lbrs", "Lower Blackrock Spire", "LBRS", 229, { 267, 268, 269, 270, 271, 272, 273, 274, 275 }, 275),
  dungeon("ubrs", "Upper Blackrock Spire", "UBRS", 229, { 3062, 3063, 3068, 3069, 3070 }, 3069, 10),
  dungeon("dm_east", "Dire Maul (East)", "DM East", 429, { 343, 344, 345, 2792, 346 }, 346),
  dungeon("dm_west", "Dire Maul (West)", "DM West", 429, { 350, 347, 348, 349, 2794, 2793, 361 }, 361),
  dungeon("dm_north", "Dire Maul (North)", "DM North", 429, { 362, 363, 364, 365, 366, 367, 368 }, 368),
  dungeon("scholo", "Scholomance", "Scholo", 289, { 2805, 2811, 2809, 2813, 3055, 2810, 2803, 2802, 2804,
    2808, 2812, 2807, 2806, 2801 }, 2801),
  dungeon("strat_live", "Stratholme (Live)", "Strat Live", 329, { 473, 474, 476, 475, 477, 472, 478, 2796,
    2797, 2798, 2799 }, 478),
  dungeon("strat_ud", "Stratholme (Undead)", "Strat UD", 329, { 2800, 479, 480, 481, 482, 483, 2795, 484 }, 484),

  raid("mc", "Molten Core", "MC", 409, 40, 1, { 663, 664, 665, 666, 667, 668, 669, 670, 671, 672 }, 672),
  raid("ony", "Onyxia's Lair", "Ony", 249, 40, 2, { 1084 }, 1084),
  raid("bwl", "Blackwing Lair", "BWL", 469, 40, 3, { 610, 611, 612, 613, 614, 615, 616, 617 }, 617),
  raid("zg", "Zul'Gurub", "ZG", 309, 20, 4, { 785, 784, 786, 787, 788, 789, 790, 791, 792, 793 }, 793),
  raid("aq20", "Ruins of Ahn'Qiraj", "AQ20", 509, 20, 5, { 718, 719, 720, 721, 722, 723 }, 723),
  raid("aq40", "Temple of Ahn'Qiraj", "AQ40", 531, 40, 6, { 709, 710, 711, 712, 713, 714, 715, 716, 717 }, 717),
  raid("naxx", "Naxxramas", "Naxx", 533, 40, 7, { 1107, 1110, 1116, 1117, 1112, 1115, 1113, 1109, 1121,
    1118, 1111, 1108, 1120, 1119, 1114 }, 1114),
}

local byKey, byEncounter = {}, {}
for _, e in ipairs(Instances.LIST) do
  byKey[e.key] = e
  for _, id in ipairs(e.bosses) do byEncounter[id] = e end
  for _, id in ipairs(e.alias or {}) do byEncounter[id] = e end
end

function Instances.Get(key)
  return byKey[key]
end

-- The entry an encounter (boss or alias) belongs to, and whether it is that entry's final boss
-- (final or aliasFinal). nil when unknown.
function Instances.ByEncounter(encounterId)
  local e = encounterId ~= nil and byEncounter[encounterId] or nil
  if not e then return nil end
  return e, e.final == encounterId or (e.aliasFinal ~= nil and e.aliasFinal == encounterId)
end

-- A new array of one kind's entries: dungeons by name, raids by tier.
function Instances.ForPicker(kind)
  local out = {}
  for _, e in ipairs(Instances.LIST) do
    if e.kind == kind then out[#out + 1] = e end
  end
  if kind == "raid" then
    table.sort(out, function(a, b) return a.tier < b.tier end)
  else
    table.sort(out, function(a, b) return a.name < b.name end)
  end
  return out
end
