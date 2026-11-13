# Ground textures

`terrain/<name>.jpg` + `<name>_n.jpg`: tiling CC0 ground sets from ambientCG (albedo 1024, normal
512, mean brightness normalised). Each act blends two of them (`WorldView3D.GROUND_SETS`); the
terrain shader tints them with the act palette. They are imported with mipmaps, which is what
keeps the ground stable under a moving camera.

| name | ambientCG id |
|---|---|
| grass | Ground037 |
| cobble_moss | PavingStones131 |
| mulch | Ground048 |
| rock | Rock030 |
| cobble | PavingStones070 |
| slate | Rock035 |
| gravel | Gravel022 |
| mossdirt | Ground068 |
