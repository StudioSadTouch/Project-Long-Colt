# Weapon Range

Map `range` ("Weapon Range") + rules `range` ("Weapon Range"). Pick both in Bot Arena or a LAN
lobby; either also works with the other maps / rules.

- Generator: `tools/range/build_range.py` (plain Python, box StaticBodies, no Blender) writes
  `scenes/levels/range.tscn` and `scenes/main/arena_range.tscn`.
- Armory: one of every weapon on the rack (3 s respawn), a second rack in front of it with the
  seven New Ottoman issue weapons, ammo crates, spawns facing down range.
- Firing lane: static dummies at 10 / 25 / 50 / 75 / 100 m (two per distance) with boards,
  strafing dummies at 15 m (walk) and 35 m (ADAD), a Spartan-pattern one at 60 m.
- Melee pit (east): static and moving dummies at sword / hammer reach.
- Blast pad (west): a dummy cluster with half cover, for rockets, grenades and the hammer.
- Rules `range`: no bots (whatever the bot count), kills never end the match, and every half
  second carried reserves refill, an emptied battery recharges and grenades top up (GameRules,
  on every peer).
- LAN: weapons, pickups and players are networked as on any map (checked with a real host +
  client: the client took a weapon off the rack through the host, and its ammo refilled).
  Dummies are local to each peer: you see your own hits on them.
- Test: `tests/range_self_test.gd`.
