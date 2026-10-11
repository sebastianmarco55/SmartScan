# Modelare 3D în Roblox Studio: cercetare pentru LostCube

Data cercetării: 11.10.2026. Destinat: (a) agentului care construiește `plugin/LostCube/Modeling/`, (b) instrucțiunilor pe care le primește Claude în plugin.
Proză în română, termeni tehnici în engleză. Fiecare afirmație ne-evidentă are o sursă `[Rn]`, `[On]`, `[An]`, `[Fn]` (lista completă cu URL-uri în secțiunea 6).

**Etichete de încredere** (puse după afirmațiile importante):
- **[V]** verificat direct: am citit documentația sau codul sursă (clonate local, vezi secțiunea 0.3).
- **[S]** doar din snippet-ul unui motor de căutare (pagina Roblox/DevForum nu a putut fi deschisă); tratează ca indicativ.
- **[D]** derivat sau testat de mine (calcul, test numeric în Python); nu e afirmația unei surse.
- **[?]** neverificat; de confirmat în Studio înainte să te bazezi pe el.

**Cuprins:** 0 Rezumat · 1 Plugin-uri și algoritmi (1.4: A triunghi/wedge, B gap fill, C poligon, D resize-align, E mirror, F array-uri, G cale/segmente, H spline-uri, I snap/aliniere, J scatter, K voxel, L CSG, M terrain, N EditableMesh, O serializare) · 2 Constrângeri Roblox · 3 Scară și stil · 4 LLM și construcție · 5 Recomandări (5.1 top 15, 5.2 parametri, 5.3 bloc pentru Claude, 5.4 note de implementare) · 6 Surse

---

## 0. Rezumat: cele 12 lucruri care contează cel mai mult

1. **Triunghi arbitrar = max. 2 `WedgePart`**, prin altitudinea pe latura lungă. Formula optimizată e în 12 rânduri (secțiunea 1.4-A). L-am verificat numeric pe 2000 de triunghiuri aleatoare [D] și apare identic în trei baze de cod independente (EgoMoose, stravant GapFill, ROBLEND) [V]. Atenție: **orientarea implicită a wedge-ului** (fața verticală la +Z, muchia subțire la -Z) rezultă din aceste trei coduri; documentația Roqer formulează invers (poate înțelege altceva prin „tip”). Recomand o auto-calibrare cu raycast la prima rulare (cod în 1.4-A).
2. **GapFill** nu e magie: două muchii; paralele -> un `Part` + max. 2 triunghiuri; neparalele și coplanare -> 1-2 triunghiuri pe baza intersecției prelungirilor; necoplanare -> 2 triunghiuri pe cea mai apropiată jumătate. Poligon -> triangulare în evantai [V][O3].
3. **`EditableMesh` merge în plugin fără buget de memorie** [V][R1], limita e 60.000 vertecși / 20.000 triunghiuri per mesh (un quad = 2 triunghiuri). `CreateMeshPartAsync` din plugin e permis (capability `Basic`) [V][R2][R30], dar costă ~22 ms fix + ~0,27 ms per 1k triunghiuri [S][F2].
4. **Un `EditableMesh` nu se salvează singur în place.** Pentru persistență trebuie `AssetService:CreateAssetAsync(em, Enum.AssetType.Mesh, ...)`: doar plugin local, încarcă fără prompt, moderat ca orice upload, ~30 upload-uri/min, iar ROBLEND raportează că cere beta-ul Studio „CreateAssetAsync Lua API” [V][R2][O6]. În plus, jocul trebuie să aibă „Allow Mesh / Image APIs” activ [V][O6]. Plan B fără upload: „bake” în wedge-uri (`Display.bake` din ROBLEND) [V].
5. **Plugin-urile pot face capturi din viewport**: `StudioCaptureService:CaptureScreenshot{Format=PNG, OutputSize=...}` -> `StudioScreenshotCapture:GetBuffer()` [V][R25][R26][R30]. Asta deschide bucla *construiește -> privește -> corectează* (Claude cu viziune), exact ce fac mcbuild și BlenderMCP (`look` cu mai multe unghiuri) [V][A1][A6]. Base64 pentru API-ul Claude: `EncodingService:Base64Encode(buffer)` [V][R30]. LostCube nu folosește încă niciuna dintre ele.
6. **Performanța**: nu există limită oficială de părți; contează draw calls, memorie și fizica. Mesh-urile cu același `MeshContent` + aceeași textură/SurfaceAppearance se instanțiază într-un singur draw call; `CanCollide/CanTouch/CanQuery=false` pe decor, `CollisionFidelity=Box` pe obiecte mici ancorate, `CastShadow=false` pe detalii mici [V][R9]. Cifrele de pe DevForum (2.000 părți neancorate, 4.000-7.000 pe hartă) sunt anecdotice [S][F19].
7. **CSG**: rezultatele peste 20.000 triunghiuri sunt simplificate la 20.000 sau dau eroare; CSG pe mesh cere geometrie *watertight*; `UnionAsync` din `GeometryService` e asincron, întoarce un array de părți fără Parent, nu merge pe Terrain, nu se apelează în rafală [V][R8][R7]. Pentru lipire în masă ROBLEND unește ierarhic câte 150 de părți per apel [V][O6].
8. **Scară**: 1 stud = 28 cm; avatar clasic ~5 studs (R15 clasic ~4,75-5,1), Rthro 5,75-6,5; WalkSpeed 16, JumpHeight 7,2, Gravity 196,2 [V][R23][R27][R29][R45][R46]. Reguli folosite de documentația oficială: hol/ușă ≥ 10 largi și pereți ≥ 10 înalți (ca să nu sară nimeni peste ei), pași de 5 studs în greybox, kit-ul Modern City pe 7,5 studs/45° [V][R19][R22]. Pentru LostCube: grilă de bază **4** (se aliniază cu voxelul de Terrain de 4 și cu tile-ul de 8 al texturilor) [D][R4][R12].
9. **LLM + 3D funcționează când modelul alege și generatoarele calculează.** Minecraft-Builder: modelul întoarce JSON de intenție, codul calculează fiecare voxel [V][A3]; CraftDAG: ComponentPlan -> IR -> VoxelPlan cu validare [V][A2]; mcbuild: DSL + randări multi-vedere + critică vizuală [V][A1]. Un exemplu de casă: 1.268 caractere ca 14 părți explicite vs 159 ca apel de generator (8x mai puțin), iar 20 de case în buclă: 25.360 vs ~120 caractere [D].
10. **Roblox are deja**: `ProceduralModel` (generator ModuleScript `OnGenerate(params, container)`, regenerare la schimbarea atributelor/dimensiunii, integrat cu undo) [V][R15]; serverul MCP din Studio cu `execute_luau`, `screen_capture`, `generate_procedural_model` [V][R16]; `GenerationService:GenerateModelAsync/GenerateMeshAsync` [V][R30][R44]. Merită ca generatoarele LostCube să poată fi emise și ca ProceduralModel.
11. **Surse sub licență permisivă** pe care le poți refolosi (cu notice): stravant GapFill și ResizeAlign (MIT), Quenty PartToTerrain (MIT), RoundifyPart (MIT), Roblox Studio-Tools (Apache-2.0). **Nu copia cod din**: F3X și EgoMoose/Articles (fără LICENSE în repo; algoritmul triunghiului e matematică, reimplementează-l), ROBLEND (GPL-2.0), Roqer (AGPL-3.0); folosește-le doar ca idei [V].
12. **Top 15 funcții** după valoare/efort sunt în secțiunea 5.1; primele trei: `describe_model` (citire înapoi compactă), infrastructura sigură (un singur undo, previzualizări non-arhivabile, yield-uri) și familia de array-uri.

### 0.1 Metodă și limite de acces
Site-urile Roblox (create.roblox.com, devforum.roblox.com, roblox.com) **nu sunt accesibile** din mediul de lucru (DNS/proxy blocat). Am folosit:
- oglinda GitHub a documentației oficiale, `Roblox/creator-docs` (commit `af5f853`, 10.10.2026), clonată local; reference YAML pentru clase și pagini .md pentru ghiduri [V];
- `API-Dump.json` din `MaximumADHD/Roblox-Client-Tracker` (ramura `roblox`) pentru existența și securitatea membrilor API [V][R30];
- cod sursă din depozite GitHub clonate: F3X, EgoMoose/Articles, stravant (GapFill, ResizeAlign, pachetul Geometry), ROBLEND, Roqer, Quenty PartToTerrain, RoundifyPart, SGSL, MirrorPro (doar README), Studio-Tools [V];
- WebSearch: doar titluri/snippet-uri; cele de pe DevForum sunt marcate **[S]**.

### 0.2 Ce NU am putut verifica (de testat în Studio)
- Persistența unui `EditableMesh` la salvarea place-ului fără upload (ROBLEND indică „nu persistă”; documentația oficială nu o spune explicit) [?].
- Dacă beta-ul „CreateAssetAsync Lua API” mai e necesar pe versiunea de Studio a utilizatorului [?].
- Dimensiunile exacte ale rig-ului R15 (HumanoidRootPart 2x2x1 din memorie) [?]; ce zonă exactă din ecran captează `StudioCaptureService` (doar 3D viewport sau tot Studio) [?].
- Orientarea implicită a `WedgePart` (vezi 1.4-A: calibrare automată).
- Detalii despre Archimedes, Brushtool, Model Reflect, Studio Build Suite, Material Flip: sunt plugin-uri închise; am doar snippet-uri [S]. „Polybattle/Moon builders” din cerere: n-am găsit niciun plugin de construcție cu acest nume; „Moon” e Moon Animator (animații), deci irelevant aici.

### 0.3 Depozite clonate (reproductibil)
`Roblox/creator-docs@af5f853`, `F3XTeam/ROBLOX-Building-Tools@8af2073` (ramura `development`), `EgoMoose/Articles@4238a71`, `stravant/roblox-gapfill@3a64335`, `stravant/roblox-resizealign@2106ffa`, `CRUPPNOMICS/ROBLEND@4d7c7ee`, `XcapeAxis/Roqer@bf7118b` (fork al `S4US/Roqer`), `Quenty/PartToTerrainPlugin@898742a`, `KhanPython/RoundifyPart@c6c231b`, `mateuszsrebrny/sledzik-games-scene-language@24355ee`, `MrPluginMaker/MirrorPro@1c83346`, `Roblox/Studio-Tools@c5ea302`.

---

## 1. Plugin-uri de construcție: ce fac, de ce sunt rapide, ce algoritmi folosesc

### 1.1 Panoramă

| Plugin | Ce face | De ce e rapid | Sursă / licență |
|---|---|---|---|
| **F3X Building Tools** | Move, Resize, Rotate, Paint, Surface, Material, Anchor, Collision, New Part, Mesh, Texture, Weld, Lighting, Decorate; export/import de build-uri | Totul într-un HUD; increment per unealtă; handle-uri; **26 de puncte de snap per piesă**; selecție prin dreptunghi, `Shift+K` (selectează piesele din interiorul selecției), grupuri numite; hotkeys pentru clone/delete/undo/redo | [O1], cod citit [V]; repo fără fișier LICENSE: doar idei |
| **GapFill & Extrude** (stravant) | 2 click-uri pe muchii -> generează `Part`/`Wedge` care umple spațiul; mod Polygon (evantai); mod Extrude pe o față | Înlocuiește calculul manual de wedge-uri; opțiuni: `ThicknessMode` = `BestGuess`/`OneStud`/`Custom`/`Thinnest`/`Plate`, `FlipDirection`, `UnionResults`, `SelectResults`; grosime implicită custom 0,2 | [O3] MIT [V]; context [F16] [S] |
| **ResizeAlign** (stravant) | 2 fețe: le redimensionează/extinde până se întâlnesc; funcționează și cu `WedgePart`/`CornerWedgePart` | Moduri `OuterTouch`, `InnerTouch`, `WedgeJoin`, `RoundedJoin`, `ButtJoint`, `ExtendUpTo`, `ExtendInto`; un singur record de undo | [O4] MIT [V] |
| **Model Reflect** (stravant) | Oglindire de modele | n/a: nu am găsit sursa | [?]; analog: **Mirror Pro** (baze `World`/`Local`/`Target`, ghost translucid, moduri de rotație, offset-uri) [O9] [V README] |
| **Archimedes 3** (Scriptos) | Arce, cercuri, cilindri din părți; „Auto-Resize” instabil (beta); mod fereastră compactă vs widget | Unghi per piesă, taste pentru „Render Once/Circle”; autorul avertizează că abuzul umflă numărul de părți și recomandă Blender pentru forme curbe; părțile transparente (sticlă) arată suprapunerile | închis [S][F11] |
| **Brushtool 2.1** (XAXA) | Pensulă de împrăștiere (copaci, bolovani, resturi) cu densitate, randomizare, aliniere | Plasare pe suprafață prin raycast sub cursor, variație aleatorie | închis [S][F15] |
| **Studio Build Suite** (Fractality; „MaterialFlip” al lui stravant apare doar în liste de plugin-uri, fără detalii), **Geometrik** (triunghi din 3 click-uri, generator de cercuri/con), **Mesher** (primitive cu rezoluție reglabilă), **Charming Studio** (bevel pentru părți și wedge-uri), **RoundifyPart** | Utilitare de formă | Geometrie generată parametric, fără mesh extern | închise [S][F10][F9][F18]; RoundifyPart: MIT, cod în repo [O10] [V README] |
| **Part to Terrain** (Quenty) | Convertește Part/Wedge/Ball/Cylinder în Terrain | Map direct la `FillBlock/FillWedge/FillBall/FillCylinder`; opțiuni „păstrează terenul / partea” | MIT [O8] [V] |
| **Tag Editor** (tiffany352; acum există unul integrat în Studio) | Etichete `CollectionService` cu culori/iconițe, „World View” | Vizualizare 3D a obiectelor etichetate | [S][O15] |
| **ROBLEND** | Editor de mesh în stil Blender peste `EditableMesh` (Edit Mode, extrude, inset, loop cut, bevel, modifiers, vertex paint) | Taste Blender (G/S/R, X/Y/Z, tastare numerică), modifiers nedistructive stocate pe parte (`RB_Mods`), „Place in Studio” | GPL-2.0 [O6] [V]: doar idei |
| **CSG To EditableMesh**, **Voxel To Part** | Convertoare | Voxel -> părți cu *greedy meshing* | [S][F13][F14][F8] |
| **Built-in Studio** | Align tool (Min/Center/Max, World/Local, relativ la Selection Bounds sau Active Object), Pivot tools (Snap la hotspots, Reset), Terrain Editor (Draw/Sculpt/Smooth/Paint/Fill/Sea Level), Material Manager („paint” cu material), Union/Intersect/Negate/Separate, Assistant, MCP | Integrate cu `Ctrl+Z`, grid, selecție | [R31][R32][R33][R42][R8][R17][R16] [V] |

Concluzii utile pentru LostCube:
- Nu există (în ce am găsit) un plugin deschis cu **arc / radial array / path array** complet; deci aceste unelte trebuie scrise de la zero (formule în 1.4-F/H) [V căutări GitHub + S].
- Cele mai bune surse de cod reutilizabil sunt GapFill (MIT), ResizeAlign (MIT) și biblioteca `stravant/geometry` (inclusă în `Packages/` din GapFill), care expune `getGeometry(part)` (vertecși/muchii/fețe pentru Block, Wedge, CornerWedge, Cylinder, Sphere) și `blackboxFindClosestMeshEdge(hit)` (până la 50 de raycast-uri pentru muchiile unui MeshPart/Union a căror geometrie nu se poate citi) [V][O5].

### 1.2 Ce le face rapide (principii comune)
1. **Din N click-uri la 1-2**: alegi *elemente geometrice* (muchii, fețe, colțuri) în loc de coordonate. Snap pe puncte fixe (F3X: 8 colțuri + 12 mijloace de muchie + 6 centre de față) [V][O1].
2. **Previzualizare apoi commit**: ghost translucid (Mirror Pro), highlight de muchie la hover (GapFill), „Place in Studio” care urmărește mouse-ul (ROBLEND) [V][O9][O3][O6].
3. **Câmpuri numerice + increment + taste** (F3X: `-` mută focusul pe increment; Studio: `Shift+2`, `Alt+R`) [V][O1][R24].
4. **Un singur pas de undo** per operație: `ChangeHistoryService:TryBeginRecording/FinishRecording`; doar o înregistrare activă per plugin [V][R38]. GapFill folosește un „virtual undo” (waypoint + atribut pe ServerStorage) pentru a anula intern pașii intermediari [V][O3].
5. **Setări persistente** (`plugin:GetSetting/SetSetting`), ex. GapFill salvează `ThicknessMode`, `CustomThickness`, `FillMode` [V][O3].
6. **Re-editabil / nedistructiv**: RoundifyPart păstrează dimensiunile originale în atribute și poate recalcula; ROBLEND păstrează mesh-ul editabil în `RB_Data` și stiva de modifiers în `RB_Mods`; ProceduralModel regenerează din parametri [V][O10][O6][R15].
7. **Reutilizează geometria nativă** a lui Studio (draggers via `DraggerFramework`, `plugin:StartDrag`) în loc să-și facă propriile gizmo-uri [V][O3 (dependența DraggerHandler)][R39].

### 1.3 Interacțiuni: hotkeys, previzualizări, snapping

**Studio nativ** [V][R24][R8]: `2/3/4` = Move/Scale/Rotate; `Shift` comută snapping în timpul tragerii; `Ctrl+L` local/world; în timpul tragerii `T` înclină 90° către cameră și `R` rotește 90° în jurul normalei; `Ctrl+T`/`Ctrl+R` rotesc 90° pe X/Y; `Alt+A` Anchor; `Ctrl+G` grup; `Alt+L` Lock; `Shift+Ctrl+G` Union, `+I` Intersect, `+N` Negate, `+U` Separate. Pivotul „face soft-snap” pe suprafețe/muchii; cu snapping activ apare o riglă pe punctul de prindere. Implicit Studio permite orice fracțiune de stud/grad, deci snapping-ul trebuie setat de utilizator [V][R22].
**API pentru a citi setările**: `plugin.GridSize`, `StudioService.GridSize`, `StudioService.RotateIncrement`, `StudioService.UseLocalSpace`, `plugin.CollisionEnabled` [V][R39][R30].

**F3X** [V][O1]: `Enter` = ciclează axele (Global -> Local -> Last), la Resize = ciclează direcțiile (Normal <-> Both); `R` ținut = snap la cel mai apropiat punct dintre cele 26 (se afișează un marker 2D); `T` = aliniază selecția la suprafața țintă; tastatura numerică 8/2/4/6/9/1 = nudge pe fețele Top/Bottom/Left/Right/Front/Back; `-` = focus pe câmpul increment; `Shift+C/X/G/F/K/R` = clone / delete / grup Model / grup Folder / prism-select / clear.

**GapFill** [V][O3]: mașină de stări `EdgeA -> EdgeB`; hover = muchia cea mai apropiată de raycast (geometrie din `stravant/geometry`; ignoră piesele `Locked`); click 1 alege muchia A și memorează normala suprafeței; click 2 face umplerea; `Ctrl` activează draggerul; click pe nimic resetează.

**Terrain Editor** [V][R33]: mărime pensulă 1-64, strength 0,1-1, pivot vertical bottom/center/top, plan blocat (Auto urmărește camera, Manual), „ignore parts”, „auto material”; `Ctrl` inversează în mod subtract; `Shift` activează Smooth.

**ROBLEND** [V][O6]: limbaj de taste Blender (G/S/R apoi X/Y/Z, număr, `Ctrl` snap, `Enter`/click confirmă, `Esc`/click-dreapta anulează); blochează scurtăturile Studio cât mouse-ul e în fereastră; atelierul de lucru stă la 10.000 studs sub hartă.

**Ghost-uri corecte în Studio** (practică + documentație): pune previzualizările într-un container cu `Archivable = false` (nu se salvează, nu se clonează) [V][R37][O9]; `CanCollide/CanTouch/CanQuery = false` și fără scripturi/sunete/constraints (Mirror Pro le curăță) [V][O9]; nu le ține în interiorul unei înregistrări `ChangeHistoryService` (altfel apar în undo); la commit: o singură înregistrare, `FinishRecording(..., Commit)` [V][R38].

### 1.4 Algoritmi (cu formule și pseudocod)

#### A. Triunghi 3D -> maximum două `WedgePart` [V][O2][O3][O6] [D: test numeric]
Idee (EgoMoose): Roblox nu are triunghi oarecare, dar are triunghi dreptunghic (wedge). Orice triunghi se împarte printr-o altitudine în două dreptunghice.
1. Fie `a, b, c`. Alege latura cea mai lungă ca bază; `a` devine vârful opus ei (`bc` = baza).
2. `right = normalize(ac × ab)`, `up = normalize(bc × right)`, `back = normalize(bc)`.
3. `height = |ab · up|`; `len1 = |ab · back|`; `len2 = |ac · back|`.
4. Wedge 1: `Size = (t, height, len1)`, `CFrame.fromMatrix((a+b)/2, right, up, back)`. Wedge 2: `Size = (t, height, len2)`, `CFrame.fromMatrix((a+c)/2, -right, up, -back)`. `t` = grosimea plăcii (>= 0,001; Size minim) [V][R5].

Luau (reimplementare proprie a matematicii din sursă; matematica testată în Python pe 2000 de triunghiuri: acoperire exactă, fără goluri, baza `(right, up, back)` cu determinant +1):
```luau
local function triWedges(a: Vector3, b: Vector3, c: Vector3, t: number, side: number?)
	local ab, ac, bc = b - a, c - a, c - b
	local abd, acd, bcd = ab:Dot(ab), ac:Dot(ac), bc:Dot(bc)
	if abd > acd and abd > bcd then c, a = a, c elseif acd > bcd and acd > abd then a, b = b, a end
	ab, ac, bc = b - a, c - a, c - b
	local n = ac:Cross(ab)
	if n.Magnitude < 1e-6 then return {} end            -- triunghi degenerat (coliniar)
	local right = n.Unit
	local up = bc:Cross(right).Unit
	local back = bc.Unit
	local h = math.abs(ab:Dot(up))
	local shift = right * (t * 0.5 * (side or 0))        -- side = +1/-1: placa pe o parte a planului; 0 = centrată
	local out = {}
	local l1, l2 = math.abs(ab:Dot(back)), math.abs(ac:Dot(back))
	if l1 > 0.001 then out[#out+1] = { size = Vector3.new(t, h, l1), cf = CFrame.fromMatrix((a + b) / 2 + shift, right, up, back) } end
	if l2 > 0.001 then out[#out+1] = { size = Vector3.new(t, h, l2), cf = CFrame.fromMatrix((a + c) / 2 + shift, -right, up, -back) } end
	return out
end
```
- **Orientarea implicită a wedge-ului** (rezultată din cod, nu din documentație): triunghiul wedge-ului are unghiul drept la local `(y = -SY/2, z = +SZ/2)`; fața verticală e la **+Z (Back)**, muchia de grosime zero la **-Z, jos**; panta urcă dinspre -Z spre +Z. Aceeași convenție apare în ResizeAlign (`getFacePoints`: „right angle at (-SY/2, +SZ/2)”) [V][O4]. Documentația Roqer (`full.md`) afirmă că „tip” e spre +Z; cele trei implementări și testul meu numeric (2000/2000 corecte sub ipoteza A, 0/2000 sub ipoteza B) nu o susțin [V][D]. **Calibrare la pornire** (cost zero, elimină orice îndoială):
```luau
local function wedgeTallSide(): string                  -- "+Z" așteptat
	local w = Instance.new("WedgePart"); w.Anchored = true; w.Size = Vector3.new(1, 4, 4)
	w.CFrame = CFrame.new(0, 1000, 0); w.Parent = workspace
	local p = RaycastParams.new(); p.FilterType = Enum.RaycastFilterType.Include; p.FilterDescendantsInstances = { w }
	local hi = workspace:Raycast(Vector3.new(0, 1010, 1.5), Vector3.new(0, -20, 0), p)
	local lo = workspace:Raycast(Vector3.new(0, 1010, -1.5), Vector3.new(0, -20, 0), p)
	w:Destroy()
	return (hi and lo and hi.Position.Y > lo.Position.Y) and "+Z" or "-Z"
end
```
- **Evitarea „sliver”-elor** (GapFill): în loc de latura cea mai lungă, alege latura pentru care proiecția vârfului opus cade cel mai aproape de mijloc: `e_i = (v·u)/|u|²` ca în cod, minimizează `|0,5 + e_i|`; dacă un `|e| < 1e-4` (unghi drept) folosește acea latură (rezultă un singur wedge). Piciorul altitudinii rămâne în interiorul laturii, deci ambele wedge-uri sunt valide [V][O3 `fillTriangle.lua`].
- **Grosime și față** (GapFill): `depth` = grosimea; semnul se alege ca placa să intre *în* geometria vecină (normala dorită sau poziția părții de referință); în poligoane, normala primului triunghi devine „hint” pentru restul [V][O3].
- **Cost**: 2 părți/triunghi. Prag practic [D]: până la ~200 de triunghiuri (~400 părți) wedge-uri; peste, `EditableMesh` (cu avertismentul de persistență din 2.4). ROBLEND „bake” folosește `thick = clamp(maxDim * 0,004, 0,05, 0,2)` [V][O6].
- Alternativă pentru „pereți” plani: dreptunghiurile se fac cu un singur `Part`, nu cu perechi de triunghiuri (GapFill pune un `Part` pe porțiunea dreptunghiulară dintre muchii paralele) [V][O3].

#### B. Gap fill între două muchii (A: `a0->a1`, B: `b0->b1`) [V][O3 `doFill.lua`]
- **Paralele** (`dirA ≈ ±dirB`, toleranță 1e-3): orientează B la fel ca A. Proiectează B pe axa lui A: `[axisMin, axisMax] = [max(0, proj(b0)), min(lenA, proj(b1))]`. Dacă intervalul e gol -> 2 triunghiuri (`fill(a0,a1,b0)`, `fill(b0,b1,a1)`). Altfel: un `Part` pe zona comună (Size = (perpLen, grosime, axisMax-axisMin), grosimea din adâncimea piesei A pe normala fill-ului sau `thicknessOverride`) + max. 2 triunghiuri la capete.
- **Neparalele**: cel mai apropiat punct între dreptele `A + t·dA` și `B + u·dB`, cu `s = B0 - A0`, `a = dA·dA`, `b = dA·dB`, `c = dB·dB`, `d = dA·s`, `e = dB·s`, `den = a·c - b²` (degenerat dacă `|den| < 1e-3`): `t = (c·d - b·e)/den`, `u = -(a·e - b·d)/den` [V]. (ResizeAlign folosește forma cu produs vectorial, stabilă numeric la unghiuri mici: `lenA = ((pB-pA)×dirB)·(dirA×dirB)/|dirA×dirB|²`, `lenB = ((pB-pA)×dirA)·(dirA×dirB)/|dirA×dirB|²` [V][O4].)
  - Coplanare, intersecția în interiorul ambelor muchii -> **un triunghi**: C = intersecția; A și B = capetele muchiilor de partea unde a făcut utilizatorul click.
  - Coplanare, intersecția în afara ambelor -> **două triunghiuri** `(extA,endA,endB)` + `(extB,endB,extA|endA)`.
  - Intersecția pe o muchie dar nu pe cealaltă -> un triunghi cu cel mai îndepărtat capăt al celeilalte.
  - **Necoplanare** -> două triunghiuri construite pe muchia A și pe jumătatea muchiei B cea mai apropiată de click (`click > 0,5 * length`).
- Pentru Claude: expune `gap_fill(edgeA:{p0,p1}, edgeB:{p0,p1}, thickness)` cu punctele explicite; fără click-uri.

#### C. Umplere de poligon [V][O3 `doPolygonFill.lua`]
Triangulare în evantai din primul vertex: `(v1, v_i, v_{i+1})`, cu `normalHint` păstrat de la primul triunghi pentru ca toate plăcile să fie pe aceeași parte. Corect pentru poligoane convexe și plane. Pentru concave [D]: *ear clipping* (O(n²)): ia 3 vertecși consecutivi, dacă colțul e convex față de normala poligonului și niciun alt vertex nu cade în triunghi, taie-l; repetă.

#### D. Resize/extend până la planul altei fețe (ResizeAlign) [V][O4]
Pentru fețele A și B cu normale `dirA`, `dirB` și puncte de plecare `pA`, `pB` (colțul cel mai îndepărtat/apropiat al piesei după mod): `crossDir = dirA × dirB`, `denom = |crossDir|²`; `lenA`, `lenB` ca la B (neparalele). Aplică `Size += |axis|·len`, `CFrame *= CFrame.new(axis·len/2)`. Dacă `lenA < -extensibil` -> operație imposibilă (nu face nimic sau cade pe comportamentul „paralel” când unghiul e sub ~0,57°, `sin < 0,01`). Limită de extindere: `min(2048, 8 × scara operației)`. `OuterTouch` + unghi ascuțit: `InnerTouch` + umplere cu wedge (`WedgeJoin`); `RoundedJoin`: cilindru de rază = raza maximă a piesei A pe axa `dirA×dirB` (sfera dacă ambele sunt cilindri). Util pentru Claude: `extend_to_plane(partA, faceA, partB, faceB, mode)`.

#### E. Reflect / mirror [D: derivat și verificat numeric; contextul funcțional din Mirror Pro [O9]]
- Plan prin punctul `p0` cu normala unitară `n`: `P' = P - 2((P - p0)·n)·n`; matricea de reflexie `M = I - 2·n·nᵀ`.
- Orientare: `R' = M·R` are determinant -1, iar `CFrame` nu poate reprezenta reflexii. Corecție: `R'' = M·R·S`, unde `S` e o reflexie *locală* sub care forma piesei este simetrică. Pentru `Block`, `Cylinder` (axa pe X), `Ball`, `WedgePart`: `S = diag(-1, 1, 1)`. Pentru `CornerWedgePart` (vârful deasupra colțului local `(+hx,-hy,-hz)`): `R'' = M·R·diag(-1,1,1)·Ry(+90°)` și **inversează `Size.X` cu `Size.Z`** (verificat pe mulțimea de vertecși din ResizeAlign) [D][O4]. Verifică `det(R'') = +1`.
- `MeshPart`/`UnionOperation`: nu se pot oglindi exact cu CFrame (nu există scară negativă); oglindește vertecșii într-un `EditableMesh` și **inversează ordinea vertecșilor fiecărei fețe** (winding antiorar = față vizibilă) [V][R1].
- Opțiuni utile (din Mirror Pro): bază World/Local/Target (partea-ancoră), mod de rotație urmărind pivotul/obiectul/selecția activă, offset XYZ după reflexie, ghost [V README][O9].

#### F. Array-uri (linear, grilă, radial, arc, pe cale) [D]
- **Linear/grilă**: `cf_i = cf0 * CFrame.new(step * i)` (step în spațiul local al piesei) sau `CFrame.new(stepWorld * i) * cf0`. Parametri: `count`, `step` sau `fit(length)` (calculează `step = (length - size)/(count-1)`); `Model:PivotTo` pentru modele.
- **Radial** în jurul unui centru `C` și axe `axis`: `cf_i = CFrame.new(C) * CFrame.fromAxisAngle(axis, θ_i) * CFrame.new(-C) * cf0`, `θ_i = start + i·sweep/count` (sweep = 2π pentru cerc complet: `count` pași; pentru arc deschis: `count-1`). Flag `faceCenter` (păstrează orientarea față de centru; implicit da).
- **Arc** (segmente drepte): pentru arc de rază exterioară `r_o` și pas unghiular `Δ`: lungimea segmentului = coarda exterioară `2·r_o·sin(Δ/2)` (capetele feței exterioare stau pe cerc; vecinii se suprapun pe interior, fără goluri pe exterior) [V][O7 `paths.md`]; centrul piesei la distanța `r_o·cos(Δ/2) - T/2` de centrul arcului (`T` = grosimea radială), cu `θ_i = θ_0 + (i + 1/2)Δ`. Număr de segmente pentru o eroare maximă (săgeată) `ε`: `n = ceil(sweep / (2·acos(1 - ε/r)))` [D]. Tabel (segmente pe cerc complet): r=4: 20/15/9 pentru ε=0,05/0,1/0,25; r=16: 40/29/18; r=64: 80/57/36 [D].
- **Pe cale/spline**: eșantionează spline-ul cu pas de lungime constantă (H), plasează instanțe cu cadru `CFrame.lookAt` sau `fromMatrix(P, N, up)` (parallel transport).

#### G. Parte între două puncte, polilinii [V][O7 `paths.md`]
`CFrame.lookAt((A+B)/2, B)` și `Size.Z = |B-A|`: nu ghici unghiuri, dă capetele. Pentru polilinie: fiecare segment între puncte consecutive; la colțurile cu unghi de viraj `φ` prelungește fiecare segment cu `(w/2)·tan(φ/2)` [D] sau pune un cilindru/sferă la îmbinări. Toate marginile (carosabil, borduri, parapete) se obțin dintr-o **singură linie centrală** decalată lateral, nu din linii desenate separat [V][O7].

#### H. Spline-uri [D]
- **Catmull-Rom centripet** (α = 0,5) între `P1,P2` cu vecinii `P0,P3`: evită cusp-urile și auto-intersecțiile. Pentru lungime constantă: eșantionează dens (≥ 10 puncte/segment), acumulează lungimea, apoi inversează prin căutare binară.
- **Cadre**: `T_i = normalize(P_{i+1} - P_{i-1})`; `N_i = normalize(N_{i-1} - (N_{i-1}·T_i)·T_i)` (parallel transport), pornind de la `up` proiectat; adaugă *bank* (rotație în jurul lui `T`).
- **Decalaje laterale**: `P_i ± N_i·w/2` pentru șosea, borduri, garduri. Tangentele pe pante: segmentul se înclină pe lungimea lui cu `CFrame.Angles(0,0,roll)` [V][O7].

#### I. Snap, aliniere, distribuție [V][O1][R31]
- 26 de puncte de snap per piesă în coordonate locale: `(±sx,±sy,±sz)` (8 colțuri), două coordonate non-zero (12 mijloace), una (6 centre) cu `s = Size/2`; alege-l pe cel mai apropiat de punctul de lovire al raycast-ului; exclude selecția curentă [V][O1].
- Aliniere (Studio): `Min`/`Center`/`Max` pe axele X/Y/Z, în World sau Local, relativ la *Selection Bounds* sau *Active Object* [V][R31]. Distribuție uniformă [D]: sortează după centru pe axă, `gap = (extent - Σsize)/(n-1)`.
- Snap la grilă: `round(x/g)*g`; citește `g` din `plugin.GridSize` [V][R39].
- „Pune pe sol / pe suprafață”: raycast în jos din deasupra bounding box-ului, `RaycastParams` cu `Exclude = {modelul}`; setează baza modelului la `hit.Position.Y` (+ scufundare opțională) [D].

#### J. Scatter (pensulă/seed) [V][O7 `scatter.md`][S F15]
Reguli verificate în Roqer: zonă XZ dreaptă, `density` = număr per 10.000 stud², `seed` întreg, 1-16 șabloane cu greutăți, `rotation = [minYaw,maxYaw]` (implicit 0-360), `scale` implicit [1,1] (recomandat 0,8-1,25), `spacing` între cercuri de amprentă, `avoid` = tag + distanță, `maxSlope` 0-89° (implicit 30), până la 20 de încercări per plasare, zero plasări = eroare, lipsa unei părți = raportat ca deficit. Algoritm [D]: dart-throwing cu grilă spațială (celulă = raza de excludere), `Random.new(seed)`, raycast pe verticală, respinge pantă > `maxSlope`, setează punctul cel mai de jos al șablonului pe hit (scufundat 20-30% pentru roci), opțional aliniere la normală cu pondere. Variație: ≥ 2 șabloane cu greutăți inegale, clustere + poieni, mai puțină densitate lângă căi/clădiri.

#### K. Voxel -> părți (greedy meshing) [S F8][D]
Pentru o grilă 3D de voxeli plini: pe fiecare strat și direcție, parcurge celulele, extinde un dreptunghi pe prima axă cât timp celulele au același material/culoare și nu sunt consumate, apoi pe a doua axă cât rândurile complete se potrivesc; emite un `Part`. Reduce numărul de părți de la O(voxeli) la ~O(suprafață). Regula Roqer: „unește celulele adiacente cu aceeași înălțime/material în blocuri mai mari” [V][O7].

#### L. CSG robust [V][R8][O6][O7]
(1) Cutterele trebuie să depășească ușor frontierele (epsilon 0,05 pe axa de trecere), altfel feței coplanare dau z-fighting sau „piele” subțire; (2) arbori CSG puțin adânci; nu scădea dintr-o parte deja unită de mai multe ori; (3) calculează lângă origine și apoi `PivotTo`; (4) `pcall` + verifică tipul rezultatului; (5) pentru multe piese: unire ierarhică pe grupuri de ≤ 150 (ROBLEND: `UnionAsync(first, rest, {SplitApart=false})`); (6) `CollisionFidelity = Box` pe uniuni decorative.

#### M. Part -> Terrain [V][O8]
`Wedge -> Terrain:FillWedge(cf, size, mat)`, `Block -> FillBlock(cf, size, mat)`, `Ball -> FillBall(pos, size.X/2, mat)`, `Cylinder -> FillCylinder(cf * CFrame.Angles(0,0,π/2), height = size.X, radius = min(size.Y,size.Z)/2, mat)`. Pentru „păstrează terenul existent” pe blocuri: citește/scrie voxeli cu `ReadVoxels/WriteVoxels` pe regiunea aliniată la 4 (`Region3:ExpandToGrid(4)`), nu `FillBlock`; pentru fiecare voxel, `offset = cf:PointToObjectSpace(centruVoxel)/4`, `factor_axa = clamp(Size_axa/8 + 0,5 - |offset_axa|, 0, min(1, Size_axa/4))`, `occupancy = min(factori)`; scrie dacă `occupancy >= 0,1` (ocupare parțială = margini netede) [V][O8][R4]. `FillWedge` are artefacte/găuri raportate pe DevForum [S][F6].

#### N. Primitive procedurale pe `EditableMesh` [V][R1][O6][O7 `modeling.md`]
- Construcție: `em:AddVertex(pos)` -> id; `em:AddTriangle(v0,v1,v2)` sau `AddFace({4 id-uri})` (quad = 2 triunghiuri); în masă: `BatchAdd(Enum.MeshAttribute.Vertex, positions)` și `BatchAdd(..., Face, {{v1,v2,v3},...})`; ID-urile sunt stabile și pot avea găuri, deci iterează cu `GetVertices()/GetFaces()`. Winding **antiorar = față vizibilă**; `MeshPart.DoubleSided` randează ambele fețe.
- **Netezime vs muchii ascuțite**: o față nouă reutilizează atributele (normală/UV/culoare) vertecșilor existenți (shading neted); pentru muchie ascuțită creează `AddNormal()` separat și `SetFaceNormals`; pentru low-poly „faceted” duplică vertecșii per față [V][R1].
- Culoare: `AddColor(color, alpha)` + `SetFaceColors(fid, {c,c,c})`; **vertex colors** sunt calea naturală pentru low-poly (fără textură, o singură paletă); lasă `MeshPart.Color` alb [V][O7 `modeling.md`].
- Forme: *lathe* (profil `(rază, înălțime)` rotit în N segmente, 6-12 pentru low-poly), *extrude* (contur 2D + înălțime), *icosphere* (20 fețe, subdivizare 1 = 80, 2 = 320 triunghiuri) + zgomot radial pentru roci/coroane [D].
- După editare: `CreateMeshPartAsync(Content.fromObject(em), {CollisionFidelity=..., RenderFidelity=...})` o singură dată la sfârșitul editării conceptuale (recalculează coliziunea) [V][R1][R2]. Pentru copii repetate: `:Clone()` pe MeshPart-ul rezultat, ca să păstrezi instanțierea (același `MeshContent`) [V][R9].

#### O. Serializare compactă de modele [V][O1 `SerializationV3.lua`]
F3X V3: array pozițional per piesă: `[tip, indexParinte, nume, size.x, size.y, size.z, cframe(12 componente), color.r,g,b, material, ...]` cu tipuri numerice (Part=0, Wedge=1, CornerWedge=2, Seat=4, Truss=5, SpecialMesh=6, Decal=8, lumini 9-11, Fire/Smoke 12-14, Model=15, Folder=18) și nume omise când sunt cele implicite. Util ca *format de citire înapoi* (nu pentru scris de către Claude).

---

## 2. Constrângeri Roblox relevante pentru modelare

### 2.1 Număr de părți și performanță

| Subiect | Fapt | Sursă |
|---|---|---|
| Limită de părți | Nu există limită oficială. Contează draw calls, memoria și fizica. Cifre anecdotice: „~13k Parts nu afectează mult dacă folosesc instancing”, „sute de mii de MeshParts ancorate merg dacă fizica e limitată”, „peste ~2.000 neancorate nu merge bine”, bugete de 4.000-7.000 de brick-uri pe hartă (vechi) | [S][F19] |
| Instancing | Mesh-urile cu același `MeshContent` se desenează într-un singur draw call dacă `SurfaceAppearance` (sau `TextureContent`) sunt identice; fără ele, dacă materialul e identic. Importul unei scene întregi ca un singur mesh strică instancing-ul (ID-uri diferite) | [V][R9] |
| Draw calls | `Render Stats > Timing` (`Shift+F2`) arată draw call-urile. Decalurile, textura (`Texture`) și particulele se grupează prost | [V][R9] |
| Mărime piesă | `Size` pe fiecare axă: 0,001-2048; sub 0,05 fizica simulează 0,05 iar randarea păstrează dimensiunea reală. F3X limitează la 0,05-2048 | [V][R5][O1] |
| Triunghiuri | Mesh ≤ 20.000 triunghiuri (specificația de import); `EditableMesh` 20.000 triunghiuri / 60.000 vertecși; `PartOperation.TriangleCount` arată numărul din uniuni | [V][R11][R1][R30] |
| `RenderFidelity` | `Automatic` (implicit): detaliu maxim sub 250 studs, mediu 250-500, minim peste 500; valori: `Automatic`, `Precise`, `Performance`. `Precise` pe prea multe mesh-uri costă | [V][R10][R9][R30] |
| Umbre | `CastShadow=false` pe părți mici/îndepărtate; sub calitatea grafică 4 umbrele se dezactivează; limitează numărul și raza luminilor | [V][R9] |
| Transparență | Straturile suprapuse de părți semi-transparente (overdraw) costă; evită sticla în straturi multiple | [V][R9][R21] |
| Streaming | `StreamingEnabled` e implicit activ la place-uri noi; `StreamingMinRadius` 64, `StreamingTargetRadius` 1024; `Model.ModelStreamingMode` (`Nonatomic`/`Atomic`/`Persistent`/`PersistentPerPlayer`); ansamblurile fizice (assemblies) intră/ies ca unitate; evită ansambluri mobile uriașe | [V][R14][R45] |
| LOD pe modele | Cu streaming activ: `Model.LevelOfDetail = SLIM` randează mesh-uri ușoare la distanță | [V][R9] |
| Cost `Humanoid` | Mare; pentru NPC-uri statice folosește `AnimationController` | [V][R9] |
| Instanțe create într-un apel | Limita „2.000 instanțe noi / 20.000 cu descendenți” este a uneltei Roqer, **nu** a platformei; dar e o limită sănătoasă pentru un tool | [V][O7] |

### 2.2 Coliziune, interogări, umbre: setările pentru decor

| Proprietate | Efect | Regulă pentru construcții |
|---|---|---|
| `CanCollide` | Interacțiune fizică. Dacă e dezactivat și piesa nu e ancorată, cade până la `FallenPartsDestroyHeight` | Decor pur: `false` [V][R5] |
| `CanTouch` | `false` = nu se mai emit `Touched/TouchEnded` | Decor pur: `false` [V][R13][R9] |
| `CanQuery` | Participare la raycast/`GetPartBounds*`. **Are efect doar când `CanCollide` e `false`** | Decor vizual: `false`, ca să ajungă razele și click-urile la suprafața reală; previzualizările (ghost) întotdeauna `false` [V][R5][O7] |
| `CastShadow` | Umbre | `false` pe piese mici (< ~1 stud) și detalii interioare; atenție la artefacte [V][R9] |
| `Anchored` | Imobilă pentru fizică; implicit `false` la `Instance.new` | Construcții statice: `true` explicit [V][R5][O7] |
| `Massless`, `CollisionGroup` | Masă / grupuri de coliziune | Doar pentru mecanisme / filtrare [V][R13] |
| `CollisionFidelity` (MeshPart/Union) | `Box` (cel mai ieftin), `Hull` (convex), `Default` (aproximare concavă), `PreciseConvexDecomposition` (cel mai scump), `Tunable` (+`CollisionPrecision`) | Piese mici ancorate: `Box`; convexe: `Hull`; obiecte mari complexe: coliziune din părți invizibile `Box`; geometria de coliziune stă în memorie chiar dacă `CanCollide=false`; nu folosi `PreciseConvexDecomposition` pe vizuale detaliate [V][R9][R10][O7] |

Model Roqer pentru coliziune stratificată: vizual cu coliziune oprită + o parte invizibilă (`Transparency=1`, `CanCollide=true`) cu fața de sus exact la înălțimea de mers; pe un șir de pereți/faleză un singur bloc de coliziune; o cutie subțire per gard [V][O7 `mesh-boundary.md`].

### 2.3 CSG / Union: limite și cauze de eșec

| Aspect | Detaliu | Sursă |
|---|---|---|
| API | `GeometryService:UnionAsync/SubtractAsync/IntersectAsync(mainPart, parts, {CollisionFidelity, RenderFidelity, SplitApart})` -> **array** de `PartOperation`/`MeshPart` fără Parent, în spațiul părții principale; `BasePart:UnionAsync` etc. există încă. Negare: tag `rbxNegate` din `CollectionService` | [V][R8][R7][R30] |
| Intrări | `Part`, `PartOperation`, `MeshPart`; **nu** Terrain. Pe `MeshPart` și pentru `SweepPartAsync`/`FragmentAsync` cere feature-ul beta „Solid Modeling On Meshes” | [V][R8][R7] |
| Watertight | Pentru mesh-uri: închis, manifold, fără auto-intersecții; fiecare muchie în exact 2 triunghiuri; altfel apelurile eșuează. Test rapid: dacă `DoubleSided` schimbă aspectul, mesh-ul e doar o coajă | [V][R8] |
| Limita de triunghiuri | Un rezultat peste 20.000 triunghiuri e simplificat la 20.000; dacă nu se poate (mii de componente disjuncte), eroare | [V][R8]; bug-uri cu mesaje criptice „error code 8” [S][F12] |
| Ritm | Nu apela o serie lungă de `UnionAsync` în rafală (asincron, costisitor) | [V][R8] |
| Rezultat | Proprietățile părții principale (Color, Material, Reflectance, Transparency, CanCollide, Anchored, CustomPhysicalProperties) se aplică rezultatului; `PartOperation` are UV boxmapped (texturi întinse) iar `MeshPart` păstrează UV-urile părții principale (celelalte fețe primesc UV `(0,0)`); `SmoothingAngle` doar din Studio (30-70° e un interval bun) | [V][R8] |
| Eșecuri frecvente | Fețe coplanare/muchii coincidente (z-fighting, „piele” subțire), geometrie non-manifold, prea multe componente disjuncte, rezultate cu „sliver”-e din părți care nu se ating exact; apelul aruncă eroare: `pcall` obligatoriu | [S][F12][V][O7 `full.md`] |
| Client | Merge pe client doar cu obiecte create pe client; nu se replică spre server | [V][R8] |
| Citirea formei | Un plugin **nu poate citi geometria** unui `UnionOperation` (ROBLEND: uniunile pot fi mutate/plasate, nu editate). Pentru muchii/vertecși pe Union/MeshPart se folosește raycast (`blackboxFindClosestMeshEdge`) | [V][O6][O5] |

### 2.4 MeshPart, `EditableMesh`, `EditableImage`: API, limite, persistență

**Clasele și metodele (confirmate în `API-Dump.json`, toate cu capability `DynamicGeneration`)** [V][R1][R30]:
- `AssetService:CreateEditableMesh()` -> `EditableMesh` sau `nil` dacă bugetul e epuizat. `CreateEditableMeshAsync(Content, {FixedSize=true})`: din asset sau din alt `EditableMesh`/`MeshPart.MeshContent`; implicit *fixed-size* (nu poți adăuga/șterge vertecși) -> pune `{FixedSize=false}` dacă schimbi topologia [V][R2].
- Elemente: `AddVertex`, `AddTriangle`, `AddFace` (3 sau 4), `AddNormal`, `AddUV`, `AddColor`; setters `SetPosition`, `SetFaceNormals/UVs/Colors`; batch: `BatchAdd(Enum.MeshAttribute, data)`, `BatchSetValues(ids, values)`, `BatchRemove`, `BatchGet*`; `MergeVertices`, `RemoveUnused`, `Triangulate`, `RaycastLocal`, `FindClosestPointOnSurface`, `GetVertices/GetFaces/GetSize/GetCenter`, `Clear`, `Destroy`. `Enum.MeshAttribute = {Vertex, Normal, Color, UV, Face}` [V][R1][R30].
- **Limite**: 60.000 vertecși, 20.000 triunghiuri (quad = 2); depășirea aruncă eroare [V][R1]. Bugetul strict de memorie e doar pe **client**; „serverul, Studio și pluginurile au memorie nelimitată” [V][R1]. Un thread raportează HTTP 429 la `CreateEditableMeshAsync` (apelul de rețea pe asset), nu la `CreateEditableMesh` [S][F5].
- **Afișare**: `AssetService:CreateMeshPartAsync(Content.fromObject(em), {CollisionFidelity, RenderFidelity, FluidFidelity})` (Yields; capability `Basic`; implicit `Default`/`Automatic`/`Automatic`). `MeshPart.MeshContent` nu se poate seta direct din scripturi (`NotAccessibleSecurity`); pentru un MeshPart existent: `MeshPart:ApplyMesh(otherMeshPart)` [V][R2][R6][R30]. Schimbările vizuale ale `EditableMesh` apar imediat, dar **coliziunea** se recalculează doar printr-un nou `CreateMeshPartAsync` (fă-l la finalul unei editări conceptuale, nu după fiecare metodă) [V][R1].
- **Cost**: ~22 ms fix + ~0,27 ms / 1k triunghiuri per `CreateMeshPartAsync`, chiar și cu `Box` și `CanCollide=false`; `Default`/`Hull` adaugă ~10 ms; nu se poate împărți pe cadre [S][F2]. Concluzie [D]: grupează geometria în puține mesh-uri mari, nu în multe mici, și fă apelul pe un thread separat cu `task.spawn`.
- **Permisiuni**: `CreateEditableMeshAsync` doar pe asset-uri deținute/partajate cu utilizatorul Studio sau cu proprietarul jocului [V][R1].
- **Joc publicat**: `EditableMesh` e dezactivat implicit; proprietarul (13+, verificat ID) trebuie să bifeze „Enable Mesh / Image APIs” în Creator Dashboard [V][R1]. În Studio, ROBLEND cere „Game Settings > Security > Allow Mesh / Image APIs” (o dată per joc) [V][O6 `Setup.lua`]. LostCube trebuie să detecteze cu `pcall(AssetService.CreateEditableMesh, AssetService)` și să afișeze instrucțiunea.
- **Persistență** [V][R2][O6]: `AssetService:CreateAssetAsync(object, assetType, {Name, Description, CreatorId, CreatorType})` acceptă `Enum.AssetType.Mesh` (rădăcină `EditableMesh`) și `Image` (`EditableImage`), plus `Model`, `Plugin`; „momentan doar în plugin-uri încărcate local, încarcă fără prompt”; rezultat `(Enum.CreateAssetResult, assetId)`; `CreateAssetResult = {Success, PermissionDenied, UploadFailed, Unknown}`. ROBLEND: fiecare salvare = upload nou, moderat, ~30/min, în jocuri de grup urcă în grup, noul asset poate avea nevoie de câteva secunde (reîncearcă `CreateMeshPartAsync(Content.fromAssetId(id))` de până la 5 ori cu 1,5 s pauză); necesită flag-ul beta „CreateAssetAsync Lua API” și restart Studio [V][O6]; anunțul inițial al API-ului spune că funcțiile beta nu merg în jocuri publicate [S][F4][F3]. **Concluzie**: un `MeshPart` cu `EditableMesh` fără upload nu supraviețuiește salvării/publicării [D, de confirmat [?]]. Plan B: `bake` în wedge-uri (cu `GeometryService:UnionAsync` ierarhic opțional) [V][O6].
- **`EditableImage`** [V][R3][R2]: `CreateEditableImage({Size=Vector2})` (implicit 512x512; **max 1024x1024**, nu se redimensionează); `CreateEditableImageAsync(Content)`; `DrawCircle/DrawLine/DrawRectangle/DrawImage/DrawImageProjected/DrawImageTransformed/SampleImageProjected`, `ReadPixelsBuffer/WritePixelsBuffer`, `Destroy`. Un singur `EditableImage` afișat se actualizează pe cadru. Se pune în `MeshPart.TextureContent` cu `Content.fromObject(img)`. `AssetService:CreateSurfaceAppearanceAsync({ColorMap, NormalMap, RoughnessMap, MetalnessMap, EmissiveMask})` creează un `SurfaceAppearance` din `EditableImage`-uri (nu mai pot fi înlocuite după creare) -> texturi PBR procedurale posibile [V][R2]. `SurfaceAppearance` nu se modifică de scripturi în joc (necesită pre-procesare), dar în plugin se creează prin această metodă [V][R41].
- **Generare AI nativă**: `GenerationService:GenerateMeshAsync/GenerateModelAsync` (scheme `Car5`, `Body1`, `TextPrompt`, max. triunghiuri opțional; implicit 10.000 la `/generate_mesh`) [V][R44][R17][R30]. Nu o recomand ca bază (cost/credite necunoscute [?]), dar poate fi o unealtă opțională.

### 2.5 Terrain

| Metodă | Semnătură / note | Sursă |
|---|---|---|
| `FillBlock(cframe, size, material)` | Bloc orientat (rotabil); suprascrie | [V][R4] |
| `FillBall(center, radius, material)` | Sferă | [V][R4] |
| `FillCylinder(cframe, height, radius, material)` | Axa cilindrului = Y local al `cframe` | [V][R4][O8] |
| `FillWedge(cframe, size, material)` | Orientare ca `WedgePart`; artefacte/găuri raportate [S][F6] | [V][R4] |
| `FillRegion(Region3, 4, material)` | `resolution` **exact 4**, regiune aliniată (`Region3:ExpandToGrid(4)`) | [V][R4] |
| `ReadVoxels/WriteVoxels(region, 4, materials, occupancy)` | Array 3D de `Enum.Material` și ocupare 0-1; max. 4.194.304 voxeli per apel; `ReadVoxelChannels/WriteVoxelChannels` pentru control mai fin | [V][R4] |
| `ReplaceMaterial(region, 4, from, to)`, `CopyRegion/PasteRegion`, `Clear`, `SetMaterialColor` | `TerrainRegion` nu se replică server/client | [V][R4] |
| Grilă | Celule 4x4x4 studs; `MaxExtents` = ±32.000 celule = ±128.000 studs | [V][R4][R34] |
| Heightmap (UI Studio) | 1 pixel = 4 studs; max. 4096x4096 | [V][R34] |
| Materiale | Terrain folosește materiale enum (Grass, Sand, Rock, Water etc.); materialele personalizate doar ca *override* global per place | [V][R34][R42] |

### 2.6 Pivot, welds, ancorare, atașamente, Archivable, grilă

- `PVInstance:PivotTo(cf)` și `GetPivot()`; `Model:PivotTo` mută toți descendenții; `Model.PrimaryPart` sau, dacă nu există, `Model.WorldPivot` definește pivotul; `Model:GetBoundingBox()` e orientat după pivot; `Model:ScaleTo(s)` scalează în jurul pivotului inclusiv lungimi de weld/constraint, atașamente, particule, `RollOffMinDistance` [V][R35]. `BasePart.PivotOffset` și `Workspace:BulkMoveTo(parts, cframes, mode)` (mutare în masă; există în dump) [V][R5][R30]. Pivot implicit = centrul; pentru piese modulare pivotul trebuie să fie *consistent* (ex. colțul de jos-față) și se mută **câte o piesă** (selecția multiplă mediază pivoturile) [V][R22][R20]. Regulă LostCube: pivotul unui model generat = centrul bazei (sau colțul de jos-față pentru kit-uri), pe Y=0 local.
- **Weld vs Anchored** [V][R36][R5]: `Anchored=true` = imobilă; o piesă neancorată legată printr-un `WeldConstraint` de una ancorată se comportă ca ancorată. `WeldConstraint`: modificarea `CFrame` mută și piesele legate, modificarea `Position` nu (recalculează offset-ul). Pentru construcții statice: ancorează tot, fără welds. Pentru obiecte mobile (uși, vehicule): un `PrimaryPart`, welds/constraints, restul neancorat; modelele cu mișcare au nevoie de `Massless` pe detalii.
- **Attachments** pentru socluri (lumini, puncte de prindere); nu se creează automat din descrieri de socket [V][O7 `world-intent.md`].
- **`Archivable`**: `false` = nu se salvează/publică și `Clone()` pe acea instanță întoarce `nil`; Duplicate/Copy-Paste din Studio ignoră proprietatea și o resetează la `true` pe copie [V][R37]. Ideal pentru ghost-uri și highlight-uri.
- **Grilă/increment**: `plugin.GridSize`, `StudioService.GridSize/RotateIncrement/UseLocalSpace` (citire) [V][R39]. Implicit Studio nu forțează snapping [V][R22]. Dimensiuni „rotunde”: 0,125/0,25/0,5; fracții precum 0,333 produc goluri vizibile [V][O7 `full.md`].
- **Ordine de operații în plugin** [V][R38][O3]: `TryBeginRecording(name)` -> modificări -> `FinishRecording(id, Commit)`; o singură înregistrare activă per plugin; după reîncărcare plugin, înregistrările neterminate nu se anulează (păstrează id-ul într-un atribut).

### 2.7 Capabilități recente utile (confirmate în API-Dump / documentație)

| Capabilitate | Detalii | Sursă |
|---|---|---|
| `StudioCaptureService` | Plugin-only. `RequestScreenshotPermissionAsync()` (utilizatorul acceptă; poate întoarce `false` fără prompt dacă setarea globală e oprită), `CanCaptureScreenshot()`, `CaptureScreenshot({Position, CaptureSize, OutputSize, ResampleMode, Format = RGBA8 \| PNG, UICaptureMode = All \| None})` -> `StudioScreenshotCapture` populat asincron (`BufferStatus`: NotStarted/Pending/Ready/Error), `GetBuffer()`, `GetErrors()`, `ScaleAsync(mode, size)`. Captura eșuează dacă regiunea cerută nu încape | [V][R25][R26][R30] |
| `SceneAnalysisService` | `GetTriangleCompositionAsync`, `GetInstanceCompositionAsync`, ... (securitate `None`); documentat pentru sesiuni Play/Test; în Edit [?] | [V][R40][R30] |
| `ProceduralModel` | `Generator` (ModuleScript), `Size`, atribute; `ForceGeneration`, `WaitForGenerationAsync` | [V][R15][R30] |
| `EncodingService` | `Base64Encode/Base64Decode(buffer) -> buffer`, `CompressBuffer/DecompressBuffer`, `ComputeStringHash/ComputeBufferHash` (securitate `None`): utile pentru imagini către Claude și pentru comprimarea/hash-ul specificațiilor stocate | [V][R30] |
| MCP built-in Studio | `execute_luau`, `screen_capture`, `generate_procedural_model`, `generate_mesh`, `search_asset`, `insert_asset`, `search_game_tree`, `inspect_instance`, `start_stop_play` etc. | [V][R16] |
| Assistant skills | Skill = document Markdown cu frontmatter (`name`, `description`, `enabled`), încărcat automat după descriere | [V][R43] |

---

## 3. Scară, proporții, stiluri

### 3.1 Dimensiuni de referință (studs)

| Obiect | Valoare | Sursă |
|---|---|---|
| Conversie | 1 stud = 28 cm; 1 m ≈ 3,57 studs (documentația de unități; comunitatea a ajuns la aceeași valoare, fără confirmare oficială veche [S]) | [V][R23]; [S][F17] |
| Avatar clasic | ~5 studs (mannequin 4,75; comunitate 5,12); Rthro normal 5,75-6,5; Rthro slender 5,25-6,25 | [V][R29][R46]; [S][F17] |
| R6 | ~5 studs în total (cap 1 + torso 2 + picioare 2; din memorie, neconfirmat în documentație) | [?] |
| Formula înălțimii R15 | `Height = 0,5 · HumanoidRootPart.Size.Y + HipHeight` (la R6 `HipHeight` e offset) | [V][R27] |
| Agent pathfinding implicit | rază 2, înălțime 5 | [V][R28] |
| Mișcare | WalkSpeed 16 stud/s; JumpHeight 7,2 (JumpPower 50 -> ~6,4 la g=196,2 [D]); Gravity 196,2 stud/s²; `MaxSlopeAngle` implicit 89° | [V][R27][R45] |
| Ușă | minim 4 lățime x 7 înălțime (Roqer); recomand 5x8 pentru jocuri cu mai mulți jucători/accesorii (agentul are diametru 4 -> 4 lățime nu lasă joc) | [V][O7]; [D] |
| Culoar / hol | ≥ 10 lățime și pereți ≥ 10 înălțime în exemplul oficial, ca doi jucători să treacă și nimeni să nu sară peste (documentația spune „jump height 5”, dar `Humanoid.JumpHeight` implicit e 7,2: barierele reale ≥ 8-10) | [V][R19][R27] |
| Tavan | 10-14 camere, 16+ holuri | [V][O7 `full.md`] |
| Blat / tejghea | 3,5-4; scaun 1,5 | [V][O7] |
| Trepte | ridicare 1, adâncime 1,5; denivelări pe rute ≤ ~2 sau rampe/scări de lățimea căii | [V][O7] |
| Căi / drumuri | cale ≥ 6; drum principal ≥ 10; mașină 12-16 lungime; butoi ~4 înălțime; sabie ~4 lungime | [V][O7] |
| Grile de kit | 5 studs (laser tag; piesa minimă 5x5, maxima 15x5, divizibile); 7,5 studs + 45° (Modern City, coliziuni oprite) | [V][R20][R22] |
| Terrain / texturi | voxel 4x4x4; textură `Part` 1024 px pe fața de 8x8 studs; Terrain 512 px / 8x8 | [V][R4][R12] |
| Rezoluție texturi pe mărime | 5x5 -> 256; 10x10 -> 512; 20x20 -> 1024; Roblox acceptă până la 4096x4096 | [V][R12] |

**Jocuri de top**: n-am găsit nicio sursă verificabilă cu dimensiuni din jocurile populare (Adopt Me, Brookhaven etc.); valorile de mai sus vin din tutorialele oficiale și din ghidul Roqer, iar thread-urile DevForum despre „scara clădirilor” sunt subiective [S]. Trateaz-o ca recomandare, nu ca standard.

Reguli de derivare (când obiectul nu e în tabel) [D]: pornește de la reperul „om = 5 studs”. Obiectele cu care jucătorul interacționează (uși, tavane, trepte) sunt mai mari decât proporțiile reale față de om (ușa reală e ~1,14x înălțimea omului; în Roblox 1,4-1,6x) ca să încapă camera, săritura și accesoriile. Pentru mobilier: `studs ≈ cm/28` (pat 200 cm = 7 studs; masă 75 cm = 2,7) dar rotunjit în sus către valorile din tabel (blat 3,5-4).

### 3.2 Grile și kit-uri modulare
- **Grilă de bază recomandată: 4** (structură), **sub-grile** 2 / 1 / 0,5 (detalii), 0,25 (garnituri) [D]. Motive: voxelul de Terrain are 4, tile-ul de textură pe `Part` are 8; 4/8/16 sunt multipli care păstrează aliniamentul cu terenul și texturile [V][R4][R12]. Oferă un parametru `kitGrid` (5 sau 7,5) pentru compatibilitate cu kit-urile oficiale [V][R20][R22].
- Piesele de kit: pivot consistent (colțul de jos-față sau punctul logic de prindere); fiecare piesă ≥ 5x5; dimensiuni maxime divizibile cu cea minimă; separă hol/perete în sub-mesh-uri numite (`UpperTrim`, `LowerTrim`, `Wall`) ca să poți schimba material/coliziune pe părți [V][R20].
- Variație fără piese noi: `MaterialVariant`/`SurfaceAppearance` interschimbabile, culoare de tint, decal de „grunge” pe pereți, recuzită (balcoane, aer condiționat, vegetație) [V][R22].

### 3.3 Ghid de stil

**Low-poly / blocky** (cel mai comun în Roblox) [V][O7 `modeling.md`, `world-intent.md`] 
- Material `SmoothPlastic` (sau vertex colors pe `EditableMesh`), culori plate, fără textură Roblox decât unde referința are textură; 5-8 culori per scenă.
- Margini: bevel de 1 segment pe muchii dure; 6-12 segmente pe curbe; shading plat pentru muchii dure.
- Bugete de triunghiuri (design, nu platformă): prop de fundal ≤ ~300, prop obișnuit ≤ ~1.500, prop erou/vehicul ≤ ~5.000.
- Grilă 4/2 (structură/pas vertical).

**Realist (PBR)** [V][R41][R12][R42]
- `SurfaceAppearance` (ColorMap albedo fără umbre „coapte”, NormalMap, RoughnessMap, MetalnessMap, EmissiveMask; `AlphaMode`: Opaque/Overlay/Transparency/TintMask; tint prin `Color` ca multiplicator, deci albedo aproape alb tintează cel mai bine); sau `MaterialVariant` pentru materiale repetabile (cu `Studs Per Tile`).
- Densitate: 1024 px per 8 studs pe `Part`; textură mai mare doar pentru elementele erou.
- Geometrie: bevel-uri mici care prind lumina, trimuri, variații de material pe aceeași clădire, zgomot/uzură prin decal-uri; coliziune separată simplă.
- Lumină: setările de iluminare ale jocului contează mai mult decât materialul; testează în mai multe medii de lumină [V][R41].

**Stilizat / cartoon** [D; sprijin parțial în O7 `world-intent.md`]
- Culori saturate și limitate, cu schimbare de nuanță în umbre; forme masive, proporții exagerate; colțuri rotunjite (cilindri la muchii, sfere la colțuri: schema RoundifyPart [V][O10]); `Neon` doar pe accente (nu luminează, adaugă `PointLight`/`SpotLight`) [V][O7 `full.md`].
- Mai puține detalii mici, siluete clare; margini „frânte” (offset de 1-2 pași de grilă) ca să nu pară diagramă [V][O7 `composition.md`].

**Compoziție (orice stil)** [V][O7 `composition.md`]: finisează fiecare margine (nu lăsa un bloc plat cu latura vizibilă), construiește relief (cel puțin o schimbare reală de nivel, monumentul pe cel mai înalt/central punct), nu aranja în inele/grile decât dacă stilul o cere (variază spațierea și yaw cu 5-20°, căi care se curbează/bifurcă), variază repetarea (≥ 2 șabloane cu greutăți inegale, scară 0,8-1,25, clustere și poieni).

### 3.4 Materiale: ce pentru ce [D, pe lista `Enum.Material` din dump [V][R30]]

| Utilizare | Material(e) | Note |
|---|---|---|
| Plastic plat / low-poly | `SmoothPlastic` | fără textură; bun la culori saturate |
| Pereți | `Brick`, `Concrete`, `Plaster`, `Cobblestone`, `Limestone` | `PaintedBrick` e material custom, nu enum |
| Podele | `WoodPlanks`, `CeramicTiles`, `Carpet`, `Marble`, `Pavement` | |
| Acoperișuri | `RoofShingles`, `ClayRoofTiles`, `Slate`, `Metal` | |
| Metal | `Metal`, `DiamondPlate`, `CorrodedMetal`, `Foil` | |
| Sticlă | `Glass` cu `Transparency` 0,3-0,6 | straturi suprapuse = overdraw [V][R9] |
| Lumină | `Neon` + `PointLight`/`SpotLight` | `Neon` nu iluminează singur |
| Natură | `Grass`, `Ground`, `Mud`, `Sand`, `Snow`, `Rock`, `Basalt`, `Slate`, `Wood` | pe Terrain: aceleași nume |
| Asfalt / drum | `Asphalt` (carosabil), `Concrete` (trotuar), `SmoothPlastic` (marcaje) | `CastShadow=false` pe marcaje |
| Fizică | Materialul schimbă și densitatea (Concrete mai grea decât Plastic) | contează doar pentru obiecte neancorate [V][R24] |

### 3.5 Palete propuse (originale, hex sRGB; pentru presetări `pal=`) [D]

| Preset | Culori (perete / acoperiș / trim / accent / sol) |
|---|---|
| `warm_village` | `#C9B79C` / `#7A3B2E` / `#5B3A29` / `#E0A458` / `#7C9A5B` |
| `medieval_stone` | `#8E8C86` / `#4A4F57` / `#5B4636` / `#9C2A2A` / `#5E7A4A` |
| `modern_city` | `#D9D9D6` / `#3C4147` / `#F2F2F2` / `#2D9CDB` / `#6B6E70` |
| `cartoon` | `#FFD166` / `#EF476F` / `#FFFFFF` / `#06D6A0` / `#118AB2` |
| `scifi` | `#2B2F3A` / `#1B1E26` / `#8FA3B8` / `#00E5FF` (Neon) / `#3A3F4B` |
| `desert` | `#D8B98A` / `#A86B3C` / `#F3E3C3` / `#2E8B8B` / `#E3C58F` |

---

## 4. Cum descrii modele unui LLM și cum construiește un LLM bine

### 4.1 Reprezentări comparate (casă 24x20, un etaj, acoperiș în două ape, ușă, 2 ferestre)

| Notație | Exemplu | Caractere | Remarci |
|---|---|---|---|
| Părți explicite (JSON) | 14 obiecte `{n,p,s,col,mat,a,...}` | 1.268 | Claude trebuie să calculeze poziții, jumătăți de înălțime, rotații; erori frecvente; la 20 de case: 25.360 caractere |
| **Apel de generator (JSON)** | `{"gen":"house","at":[0,0,0],"w":24,"d":20,"roof":"gable","door":{"side":"S"},"windows":["E","W"],"pal":"warm_village"}` | 159 | ~8x mai puțin; geometria o calculează codul |
| Linie DSL | `house at=0,0,0 w=24 d=20 roof=gable door=S window=E,W pal=warm` | 62 | Cel mai scurt; mai greu de validat/extins decât JSON |
| Generator + array | `{"gen":"house",...,"array":{"count":20,"step":[40,0,0]}}` | ~122 | Reducere ~200x față de 20 de case explicite |
(numerele: măsurate de mine cu un script Python pe aceste exemple; ordin de mărime, nu număr de tokeni [D])

Principii de design pentru specificația JSON (fiecare vine dintr-o sursă):
1. **Modelul alege, codul calculează**: JSON de „intenție” cu id-uri dintr-o listă albă (structuri, stiluri, materiale), numere limitate prin *clamp*, valori necunoscute -> implicit; același seed = același rezultat; poate fi testat fără rețea [V][A3]. Nivel semantic (camere, uși, ferestre, acoperișuri) în loc de coordonate, apoi expansiune deterministă, validare în 3 puncte [V][A2].
2. **Dimensiuni numite, fără numere magice**; poziții relative la ancora unui părinte, nu coordonate lumii ghicite [V][O7].
3. **Ancore verbale** (`center bottom center`) în loc de calcul de jumătăți de înălțime; scrise o dată pe obiect [V][O11]. Aceeași idee pentru modele inserate: pivotul unui Model fără PrimaryPart e centrul bounding box-ului, deci „la sol” înseamnă `Y = bboxHeight/2` dacă nu setezi ancora [V][O11].
4. **Capete în loc de unghiuri** pentru orice se întinde între două puncte (`CFrame.lookAt`), direcția rotațiilor se greșește ușor [V][O7].
5. **Componente + instanțe** (`component`, `instance`, `repeat count/step`, `mirror`, `scale`), cu parametri expresie, transformări compuse prin arbore [V][O11].
6. **Palete cu nume** (slot -> {culoare RGB, material}) și, pentru o lume, un `WorldSpec` JSON salvat în place (`ServerStorage`): `buildRoot`, `origin`, `style`, `grid`, `verticalStep`, `palette`, `budgets`; kit-uri și zone ca documente mici (< 32 KiB), cu `schemaVersion` [V][O7 `world-intent.md`].
7. **Citire înapoi compactă** a rezultatului (4.3) ca să închidă bucla.

Exemplu de specificație țintă (doar ilustrativ; schema reală e a motorului):
```json
{"v":1,"root":"Village_A","origin":[0,0,0],"grid":4,"style":"low_poly","pal":"warm_village",
 "nodes":[
  {"gen":"house","id":"h1","at":[0,0,0],"w":24,"d":20,"floors":1,"roof":"gable","door":{"side":"S"},"windows":["E","W"]},
  {"gen":"house","id":"h2","at":[40,0,0],"w":16,"d":16,"floors":2,"roof":"hip","door":{"side":"S"}},
  {"gen":"fence","path":[[-8,0,24],[56,0,24]],"h":4,"post_every":6},
  {"op":"scatter","of":{"gen":"tree","kind":"oak"},"zone":[[-20,-30],[70,-10]],"density":6,"seed":42},
  {"op":"mirror","ids":["h1"],"plane":"x","at":-30}],
 "budget":{"max_parts":600}}
```

### 4.2 Fluxul care funcționează: plan -> blockout -> detaliu -> optimizare -> verificare
| Faza | Ce face Claude | Bază |
|---|---|---|
| 1. Plan | Scop, stil, amprentă, înălțime, paletă, buget; o singură întrebare doar dacă dimensiunea/stilul e necunoscut. Stil „chain-of-thought”: sinteză de layout (componente, dimensiuni, ordine de construcție) înainte de cod | [V][A4][R18] |
| 2. Blockout (greybox) | Volume simple, trasee, niveluri, lățimi (≥ 6 căi, ≥ 10 holuri), fără detalii; verifică proporțiile față de personaj | [V][R19][O7] |
| 3. Verificare | `describe` + capturi din 3-4 unghiuri; repară prima dată cele mai mari defecte | [V][A1][A6] |
| 4. Structură și goluri | Pereți, uși/ferestre, scări, acoperiș prin generatoare | [V][O7] |
| 5. Detaliu | Recuzită, vegetație (scatter cu seed), trimuri; reutilizează șabloane | [V][O7] |
| 6. Optimizare | Setări coliziune/umbre, unire de cutii adiacente, șabloane clonate, buget | [V][R9][R21] |
| 7. Raport | Ce s-a construit (nume/căi), dimensiuni, număr de părți, ce rămâne (ex. mesh fără upload) | [V][O7] |

Faze în batch-uri delimitate: ground -> shell-uri de zonă -> repere -> recuzită -> mediu; fiecare fază = o operație atomică cu un singur undo; citește conturile/limitele returnate înainte de pasul următor [V][O7]. Reparație locală (bucla „vizual”): numește *un* defect observabil, alege cel mai mic domeniu (componentă, kit, zonă), o mutație, citire înapoi, captură „după” din aceeași vedere; dacă două încercări consecutive nu repară defectul, oprește-te și raportează [V][O7 `visual-repair.md`].

### 4.3 Verificare prin citire înapoi și prin imagine

**Citire înapoi (`describe_model`)** — text compact, fără a trimite tot arborele [D, structurat după rapoartele Roqer/mcbuild [V][O7][A1]]:
```
Model Village_A  bbox 96x14.2x60 (min -20,0,-30)  parts 187  meshparts 0  unions 0  tris~2.2k
materials: Brick 64, WoodPlanks 18, RoofShingles 40, SmoothPlastic 65 | anchored 187/187 | collide 41/187
issues: 2 floating (h2/Chimney, f3/Post07 y+0.5), 1 overlap (h1/Door x h1/WallS_L 0.4), 0 default-gray
checks: door h1 5x8 ok | stairs none | path width min 6.0 ok | budget parts 187/600
```
Ce să calculeze: bounding box și dimensiuni; numărul pe clasă/material; piese neancorate; culori/materiale implicite; piese „în aer” (raycast în jos din centrul bazei) sau îngropate; suprapuneri (`GetPartBoundsInBox` cu `OverlapParams`); piese sub sol; coliziune activă pe decor; triunghiuri (`PartOperation.TriangleCount`, `SceneAnalysisService:GetTriangleCompositionAsync` [?]); lățimi de ușă/cale față de minimele din 3.1.

**Imagine**: `StudioCaptureService` [V][R25][R26] (necesită permisiunea utilizatorului; verifică `CanCaptureScreenshot()`):
1. Salvează camera (`workspace.CurrentCamera.CFrame`, `FieldOfView`); ascunde ghost-urile și selecția.
2. Pentru fiecare vedere (iso NE, iso SV, de sus, din față): `dist = R / sin(FOV/2) * 1,15` unde `R` = jumătate din diagonala bounding box-ului; `cam.CFrame = CFrame.lookAt(center + dir * dist, center)`; așteaptă 2-3 cadre (`RunService.Heartbeat:Wait()`).
3. `CaptureScreenshot({CaptureSize = viewport, OutputSize = Vector2.new(768, 432), ResampleMode = Enum.ResamplerMode.Default, Format = Enum.StudioCaptureScreenshotFormat.PNG, UICaptureMode = Enum.UICaptureMode.None})`; poll `BufferStatus` până la `Ready`; `GetBuffer()` -> octeți PNG -> base64 prin `EncodingService:Base64Encode(buffer)` (întoarce tot un `buffer`; apoi `buffer.tostring`) [V][R30] -> bloc `image` (`{type="image", source={type="base64", media_type="image/png", data=...}}`) în mesajul către Claude sau în `tool_result` (computer use întoarce screenshot-uri în `tool_result`) [?]. Dimensiunea regiunii trebuie să încapă în viewport (altfel captura eșuează) [V][R25]; ce captează exact (doar 3D viewport sau tot Studio) [?].
4. Restaurează camera. Costul în tokeni: aprox. 1 token per patch de 28x28 px, deci 1280x720 ≈ 1.200 tokeni; latura lungă maximă acceptată 2576 px pe modelele curente [?: din documentația locală a skill-ului `claude-api` (`shared/cost-optimization.md`, `shared/model-migration.md`); verifică la https://platform.claude.com/docs/en/build-with-claude/vision.md]. 768x432 per vedere ≈ 420 tokeni, deci 4 vederi ≈ 1.700 tokeni: un compromis bun [D].
mcbuild trimite o „foaie de contact” cu până la 8 vederi (izometrice, de sus, secțiuni) plus dimensiuni/număr de blocuri/materiale; BlenderMCP oferă `look` cu vedere de camera/multi-unghi/wireframe/X-ray [V][A1][A6]. SceneCraft are o buclă interioară cu randare și auto-critică; SceneAssistant observă că multe sisteme rulează „open-loop”, fără rafinare pe baza randărilor [S][A7].

Ce NU dovedește o captură: coliziune, parcurgere, dimensiuni exacte, scripturi, performanță [V][O7 `visual-repair.md`]. Combin-o mereu cu citirea înapoi.

### 4.4 Moduri de eșec ale LLM-urilor în construcții și remediul

| Eșec | Remediu |
|---|---|
| Aritmetică de coordonate, jumătăți de înălțime, offset-uri | Ancore verbale, `ground:"auto"`, generatoare; builder-ul calculează |
| Semnul/sensul rotațiilor | Orientare prin `side` (N/E/S/W), `facing`, capete de segment; convenția documentată: yaw 0 privește spre -Z, `-90` spre +X [V][O7] |
| Piese în aer / îngropate | Snap pe sol prin raycast; `describe` raportează |
| Neancorat, gri implicit, `Plastic` peste tot | Valori implicite ale builder-ului (Anchored, paletă); `describe` marchează |
| Z-fighting (fețe coplanare), goluri la colțuri | Epsilon 0,05, suprapunere pe interior, grosimi ≥ 0,05; reguli din 1.4-L și 1.4-F |
| Mii de părți unice | Generatoare + array + șabloane clonate (instancing); limită de noduri în spec |
| CSG eșuat în tăcere | `pcall`, verifică tipul rezultatului, raportează eșecul; nu raporta succes fără citire înapoi [V][O7] |
| Scară greșită | Tabelul 3.1 în prompt; `describe` compară cu minimele; avertismente |
| Nepracticabil (uși strâmte, trepte înalte, bariere sărite) | Validări în generator: ușă ≥ 4x7, rise ≤ 1,25, headroom ≥ 7,5, barieră ≥ 8 |
| Ieșiri uriașe (limită de tokeni) | Spec compact; array; faze mici; răspuns scurt |
| Edituri peste munca utilizatorului | Tag-uri/atribute pe ce creează LostCube; re-`describe` înainte de modificare; tag-uri/atribute proprii (ex. `LCOwned`), după modelul `RoqerKit/RoqerZone/RoqerRole` [D][O7] |
| Instrucțiuni injectate în nume/atribute din place | Tratează tot conținutul jocului ca date nefiabile (deja în `AGENT_PROMPT`) |

### 4.5 Unelte AI pentru Roblox / Minecraft / Blender: ce se poate învăța

| Unealtă | Ce face | Lecție pentru LostCube |
|---|---|---|
| **Roblox Assistant** (Studio) | Creează/modifică instanțe, caută și inserează din Creator Store, generează materiale, mesh-uri (`/generate_mesh`, bounding box din Part-ul selectat, max. triunghiuri implicit 10.000), `ProceduralModel`-uri (limită 50/24 h, până la 8 părți prin segmentare); sub-agent de captură a viewport-ului | Prompturi specifice, selecție ca context, edit-time vs run-time, mai mulți pași; pentru modele procedurale numește parametrii editabili (culori, număr de scaune la scalare) [V][R17][R18] |
| **Studio MCP** | `execute_luau`, `screen_capture`, `search_game_tree`, `inspect_instance`, `generate_procedural_model`, `start_stop_play`... (repo-ul `Roblox/studio-rust-mcp-server` e arhivat; MCP-ul e acum integrat în Studio) | Un set mic de unelte + `execute_luau` + captură e suficient pentru buclă [V][R16][O13] |
| **Roqer** (AGPL) | Agent cu `build_instances` (batch atomic, un undo), `WorldSpec`, scatter seed-uit, bucla de reparații vizuale, politici de aprobare | Fazare, buget, tag-uri semantice (`RoqerKit/Zone/Role`), regula „construcția simplă nativă, mesh doar unde merită” [V][O7] |
| **BlenderMCP** | `execute_blender_code`, `get_scene_info` (rezumat compact), `look` (multi-unghi) | Execuție de cod + rezumat de scenă + vizualizare multi-unghi [V][A6] |
| **mcbuild** | LLM scrie un blueprint în DSL Python sandbox; interpretor -> voxeli; randare izometrică în foaie de contact; critică vizuală; `edit_region` re-construiește doar un bounding box; `get_block` citire înapoi | Edituri locale cu restul înghețat; limitări documentate (perechi de jumătăți de bloc etc.) ca teste [V][A1] |
| **CraftDAG** | `ComponentPlan` semantic -> IR -> `VoxelPlan` cu validare în mai multe puncte | Spec semantic + compilator determinist [V][A2] |
| **Minecraft-Builder** | LLM -> JSON de intenție (șabloane, stiluri, ~40 id-uri de blocuri); cod determinist pentru voxeli | Whitelist, clamp, fallback, seed, teste offline [V][A3] |
| **APT** | Sinteză de layout (CoT) -> cod de blueprint -> execuție; memorie și auto-reflecție | Planificare explicită înainte de generare [V README][S][A4] |
| **LL3M** | Agenți multipli scriu Blender Python, rulează, își critică randările, RAG pe documentația API | Cod ca reprezentare; erorile de execuție înapoi la model; RAG pe documentația API (relevant: lista de generatoare + schema ca document) [V][A5] |
| **SceneCraft / Holodeck** | Scene graph + cod Blender / constrângeri spațiale rezolvate prin optimizare | Constrângeri relaționale (în fața, aliniat, la distanță) ca nivel peste coordonate [S][A7] |
| **Forkuri MCP Roblox** | `smart_duplicate`, `mass_create_objects` | Unelte masive de duplicare/creare sunt deja standard [S][O16] |

### 4.6 Generatoarele ca `ProceduralModel`
`ProceduralModel` + modul generator `OnGenerate(params, targetContainer)` cu `Attributes` implicite, `Size`, `Pause()` pentru lucru mare; regenerare la schimbarea atributelor/dimensiunii; grupat cu schimbarea în undo; conținutul în `GeneratedFolder`; nu merge în `Actor`; joint-urile create cu draggerii nu se păstrează la regenerare; modulele inserate din Creator Store sunt sandboxed [V][R15]. Dacă `Instance.new("ProceduralModel")` merge (verifică cu `pcall`) [?], un generator scris ca funcție pură `(params) -> listă de părți` poate fi folosit atât de builder-ul LostCube cât și ca `OnGenerate`, iar utilizatorul poate ulterior schimba parametrii din Properties fără LostCube. Merită ca opțiune „Exportă ca ProceduralModel”.

---

## 5. Recomandări concrete pentru LostCube

### 5.1 Top 15 funcții după valoare / efort
Valoare 1-5 (impact asupra construirii rapide și corecte, de către utilizator și de Claude), efort 1-5 (1 ≈ o zi, 5 ≈ o săptămână) [D]. Ordonat după V/E, apoi după valoare.

| # | Funcție | V | E | V/E | Note / dependențe |
|---|---|---|---|---|---|
| 1 | **`describe_model`**: citire înapoi compactă (bbox, număr, materiale, ancorare, „în aer”, suprapuneri, culori implicite, bugete, validări de scară) | 5 | 1 | 5,0 | Fundația buclei de verificare; text < 1,5k caractere |
| 2 | **Infrastructură sigură**: o înregistrare undo per operație, ghost-uri `Archivable=false` + `CanQuery=false`, `pcall` pe toate API-urile, yield-uri la 300-500 de părți, detecție de capabilități (EditableMesh, CreateAssetAsync, StudioCaptureService, ProceduralModel) | 4 | 1 | 4,0 | Vezi 5.4 |
| 3 | **Array-uri**: liniar, grilă, radial, arc, pe cale (cu `fit`, `faceCenter`, seed) | 5 | 2 | 2,5 | Formule 1.4-F; test automat de goluri/suprapuneri |
| 4 | **Triangle / GapFill / Polygon fill** (wedge-uri) + calibrare wedge | 4 | 2 | 2,0 | 1.4-A,B,C; test pe 2000 de triunghiuri aleatoare |
| 5 | **Mirror / reflect** (părți, modele, EditableMesh cu winding inversat) | 4 | 2 | 2,0 | 1.4-E; verifică `det(R) = +1` |
| 6 | **Align / distribute / snap la sol și la suprafață** (raycast, 26 puncte, `plugin.GridSize`) | 4 | 2 | 2,0 | 1.4-I |
| 7 | **Pass de optimizare**: flag-uri de coliziune/umbre pe decor, ancorare, `CollisionFidelity`, unire de cutii adiacente (greedy), deduplicare de șabloane, raport înainte/după | 4 | 2 | 2,0 | 2.1-2.2; 1.4-K |
| 8 | **Constructor din spec JSON + generatoare** (case, scări, garduri, poduri, turnuri, drumuri, copaci, roci, mobilier) | 5 | 3 | 1,7 | (în lucru) tabelele 5.2 |
| 9 | **Captură de viewport multi-unghi pentru Claude** (viziune) | 5 | 3 | 1,7 | 4.3; permisiune; `EncodingService:Base64Encode` |
| 10 | **CSG sigur**: wrapper cu `pcall`, epsilon, unire ierarhică în grupuri ≤ 150, `CollisionFidelity=Box`, negare cu tag `rbxNegate` | 3 | 2 | 1,5 | 1.4-L |
| 11 | **Ajutoare Terrain**: Part -> Terrain (cu ocupare parțială), aplatizare sub clădire, teren din zgomot/heightmap, `ReplaceMaterial` | 3 | 2 | 1,5 | 1.4-M |
| 12 | **`WorldSpec` + tag-uri/atribute + palete și stiluri** (în place, JSON mic, versiune) | 3 | 2 | 1,5 | 4.1; consistență între sesiuni |
| 13 | **Scatter seed-uit** (raycast, pantă, evitare tag-uri, greutăți, scară/yaw) | 4 | 3 | 1,3 | 1.4-J |
| 14 | **Spline / path tools** (Catmull-Rom centripet, cadre, decalări; drum, șină, gard, râu) | 4 | 3 | 1,3 | 1.4-H,G |
| 15 | **Props procedurale pe `EditableMesh`** (lathe, extrude, icosphere + zgomot, vertex colors, bevel) cu flux de persistență (upload sau bake) | 4 | 4 | 1,0 | 2.4, 1.4-N; cere „Allow Mesh/Image APIs” |

Următoarele (V/E mai mic sau dependente): export `ProceduralModel` (3/3), previzualizare ghost interactivă cu taste (3/3), snapping de kit modular (3/3), voxel -> părți greedy (3/3), unelte de generare AI native `GenerationService` (2/3).

### 5.2 Parametri impliciți pe generator (studs, grade)
Legendă: **[src: X]** valoare luată dintr-o sursă citată, **[D]** recomandare proprie (rațiune în coloana Notă). Grilă implicită: 4; sub-grile 2/1/0,5; grosimi ≥ 0,25.

**Casă / clădire (`house`, `building`)**
| Parametru | Default | Interval | Notă |
|---|---|---|---|
| `w` x `d` | 24 x 20 | 12-64 | multipli de 4 [D] |
| `floors` / `storyHeight` | 1 / 12 | 1-6 / 10-14 | tavan 10-14 [src: O7]; 12 = 3 pași de grilă |
| `wallThickness` | 1 (ext), 0,5 (int) | 0,5-2 | [D] |
| `slab` (placă) | 1 | 0,5-2 | [D] |
| `door` | 5 x 8 | min 4 x 7 | minim [src: O7]; 5x8 pentru joc multi-jucător [D] |
| `window` | 4 x 4, pervaz la 3,5-4 | 2-6 | pervaz = înălțime tejghea [src: O7] |
| `windowSpacing` | 8 (centru-centru) | 6-16 | [D] |
| `roof` | `gable`, pantă 30°, streașină 2, grosime 1 | `gable`/`hip`/`flat`; 25-40° | rise = (span/2)·tan(pantă): span 20, 30° -> 5,77 [D] |
| `plinth` (soclu) | 1 | 0-2 | [D] |
| Material | pereți `Brick`/`Concrete`/`Plaster`, acoperiș `RoofShingles`, podea `WoodPlanks`, sticlă `Glass` 0,5 | | 3.4 |
| Buget părți | 30-60 (erou ≤ 120) | | [D] |

**Scări (`stairs`)**
| Parametru | Default | Interval | Notă |
|---|---|---|---|
| `rise` / `run` | 1 / 1,5 | 0,8-1,25 / 1,25-2 | [src: O7] ; număr trepte `n = round(H/rise)`, `rise' = H/n` [D] |
| `width` | 6 | 4-12 | cale ≥ 6 [src: O7] |
| `landing` | la fiecare 12 trepte, lungime 6 | | [D] |
| `headroom` | ≥ 8 | 7,5-12 | agent înălțime 5, săritură 7,2 [src: R27/R28] |
| `rail` | înălțime 3,5, grosime 0,4 | | [D] |
| `kind` | `steps` / `ramp` (un `WedgePart` de pantă) / `spiral` | | spirală: `r_in` 3, `r_out = r_in + width`, 16 trepte/tură (`Δθ = 22,5°`), treapta = cutie `(width, rise, r_out·Δθ·1,05)` rotită cu `θ_i` [D] |
| Buget | 1 parte/treaptă (≤ 40) sau 1 wedge | | |

**Gard (`fence`)**
| Parametru | Default | Interval | Notă |
|---|---|---|---|
| `h` | 4 | 3-6 (decor); **≥ 8 dacă trebuie să blocheze** | săritură 7,2 [src: R27] |
| `post_every` / `post` | 6 / 0,5x0,5 | 4-8 | grilă pe 2 [D] |
| `rails` | 2, grosime 0,3, la 0,35 h și 0,8 h | 1-3 | [D] |
| `pickets` | lățime 0,4, gol 0,3 (opțional) | | prea multe părți: pune-le într-un mesh [D] |
| Coliziune | **o singură** cutie invizibilă per tronson, restul `CanCollide=false` | | [src: O7] |
| Material | `Wood`/`WoodPlanks` sau `Metal` | | |

**Pod (`bridge`)**
| Parametru | Default | Interval | Notă |
|---|---|---|---|
| `width` | 12 | 8-24 | cale ≥ 6, drum ≥ 10 [src: O7] |
| `deck` | grosime 1,5 | 1-3 | [D] |
| `rail` | 4 înălțime, stâlp la 6 | | [D] |
| `kind` | `beam` (piloni la 24-32), `arch`, `suspension` | | arc: săgeată `f` ≈ span/6, rază `R = (S²/4 + f²)/(2f)`, semiunghi `α = asin(S/(2R))` [D] |
| Segmentare arc | ε = 0,25 (coarda 2·R·sin(Δ/2)) | 0,1-0,5 | 1.4-F [src: O7] |
| Suspensie | turn înălțime ≈ span/5; cabluri parabolă, un segment la ~4 studs | | [D] |

**Turn (`tower`)**
| Parametru | Default | Interval | Notă |
|---|---|---|---|
| Plan | octogon (8 laturi) sau rotund 16 | 4/6/8/12/16 | corect cu 1.4-F; rotund = `r` 8 |
| `radius` / `height` | 8 / 48 | 6-16 / 24-120 | [D] |
| `wall` | 2 | 1-3 | [D] |
| `floors` | la 12 | | tavan 10-14 [src: O7] |
| Parapet | creneluri 2 lățime x 3 înălțime, pas 4 | | grilă 4 [D] |
| Ferestre | fante 1,5 x 5, la 90° | | [D] |
| Acoperiș | con (lathe pe `EditableMesh`) înălțime = 1,5·`radius` sau piramidă din wedge-uri | | |
| Ușă | 5 x 8 | | |

**Drum (`road`)**
| Parametru | Default | Interval | Notă |
|---|---|---|---|
| `lane` | 12 | 10-14 | drum principal ≥ 10 [src: O7] |
| `lanes` | 2 (24 total) | 1-4 | [D] |
| Trotuar | 6 lățime, bordură 0,5x0,5 | | [D] |
| Grosime | 1 (suprafața la y=0) | | [D] |
| Marcaje | linie întreruptă 0,5 x 6, pauză 6; trecere 1 x 8 pas 2 | | `CastShadow=false`, `SmoothPlastic` [D] |
| Segmentare | pe linia centrală; lungime max. 16 pe dreapta, coarda 2·r·sin(Δ/2) pe curbe, ε = 0,25 | | [src: O7] |
| Înclinare / bank | pantă ≤ 15°, bank ≤ 8° | | [D] |
| Material | `Asphalt` + `Concrete` | | |

**Copaci (`tree`)** — mesh sau părți
| Parametru | Default | Interval | Notă |
|---|---|---|---|
| Trunchi | rază 1, înălțime 10 | 0,6-2 / 6-20 | cilindru: axa e **X** (`Size = (h, d, d)`, rotație Z π/2) [src: O7 `full.md`] |
| Coroană | rază 6 | 4-10 | `Ball` e uniform; coroana = 2-3 sfere suprapuse sau mesh |
| Variante / scară / yaw | ≥ 3 / 0,8-1,25 / 0-360 | | [src: O7] |
| Buget | ≤ 6 părți **sau** mesh ≤ 300 triunghiuri (fundal), ≤ 1.500 (obișnuit), ≤ 5.000 (erou) | | [src: O7] |
| Coliziune | doar trunchiul, cutie invizibilă; coroană `CanCollide=false` | | [src: O7] |
| Culori | trunchi `#6B4A2F`, frunziș `#4F8F3A` ±8% nuanță | | [D] |

**Roci (`rock`)**
| Parametru | Default | Interval | Notă |
|---|---|---|---|
| Rază | 2 | 0,5-8 | |
| Icosphere | subdiviziune 1 (80 tri) / 2 (320 tri) | 0-2 | [D] |
| Zgomot radial | 0,25·rază | 0,1-0,4 | [D] |
| Turtire Y | 0,6-0,9 | | [D] |
| Îngropare | 20-30% | | roci „așezate” [src: O7] |
| Clustere | 3-5 elemente | | grupate, nu plăci izolate [src: O7] |
| Coliziune | `Hull` (sau `Box` mici, fără pe cele foarte mici) | | [src: O7] |
| Material | `Slate`/`Basalt`/`Rock`, variație de gri ±8% | | |

**Mobilier (`furniture`)** (L x H x l)
| Obiect | Dimensiuni | Notă |
|---|---|---|
| Masă | 6 x 3,5 x 3 (blat 0,4, picioare 0,4) | blat 3,5-4 [src: O7] |
| Scaun | 2 x 3,5 x 2 (șezut la 1,5) | șezut 1,5 [src: O7] |
| Canapea | 7 x 2,8 x 3 (șezut 1,5) | [D] |
| Pat | 7 x 1,8 x 5 | 200 cm / 28 ≈ 7 [D][R23] |
| Raft | 4 x 6 x 1,5 | [D] |
| Bancă | 6 x 3 x 2 (șezut 1,5) | [D] |
| Felinar stradal | stâlp 0,5, înălțime 10-12, lumină `PointLight` raza 24 | [D] |
| Butoi / ladă | 3 x 4 x 3 / 3 x 3 x 3 | butoi ~4 [src: O7] |

### 5.3 Bloc de instrucțiuni pentru Claude (copiabil în system prompt; ≤ 40 de linii)
Numele uneltelor (`build`, `describe`, `capture`, `edit`) sunt substituibile cu cele reale.
```text
## Building in Roblox Studio (LostCube Modeling)
Units: studs and degrees, Y up, forward = -Z (yaw 0 faces -Z). 1 stud = 28 cm. Player ~5 tall, jump 7.2, walk 16.
1. Plan first, in 2-5 lines: purpose, style (low_poly | realistic | cartoon), footprint, height, palette, part budget. Ask at most one question, only if size or style is truly unknown.
2. Never emit hundreds of single parts. Use generators (house, stairs, fence, bridge, tower, road, tree, rock, furniture) and ops (array, mirror, scatter, align). Raw parts only for one-off details.
3. Describe, do not compute: give sizes, counts, sides (N/E/S/W), anchors ("ground", "center-bottom") and endpoints for anything running between two points. Never compute rotations, half-heights or world offsets yourself; the builder does.
4. Work in phases, each one undo step: blockout (ground, volumes, routes) -> check -> structure and openings -> detail and props -> optimize. Do not detail before the blockout passes the check.
5. Grid 4 (2 and 1 for details); use round values (multiples of 0.25). Mirror or array instead of repeating.
6. Scale (studs): door >= 5x8 (min 4x7), hallway >= 10 wide, ceiling 10-14, stairs rise 1 / run 1.5, path >= 6, road lane 12, tabletop 3.5, seat 1.5, car 12-16 long. A barrier meant to stop players must be >= 8 high.
7. Style: low_poly = SmoothPlastic or vertex colors, 5-8 flat colors, bevel 0.25-0.5; realistic = real Materials (Brick, Concrete, WoodPlanks...) or SurfaceAppearance; cartoon = saturated palette, rounded edges. Always use a named palette; never leave default gray.
8. Keep defaults: Anchored=true; decor CanCollide/CanTouch/CanQuery=false; small details CastShadow=false; walls/fences get ONE invisible collision box per run; MeshPart CollisionFidelity Box or Hull. Keep gameplay parts (spawns, triggers, doors) separate from decor.
9. Repetition: clone one template (same mesh) instead of unique parts; scatter with a seed, 2+ variants, scale 0.8-1.25, yaw 0-360.
10. Budgets: house <= 60 parts, prop <= 12 parts or one mesh <= 1500 tris, scene as agreed. Prefer merged boxes and meshes over unions; use unions only for holes/curves, near origin, and check the result.
11. Verify every phase: describe (bounds, counts, floating, overlaps, unanchored, default color, budget) AND capture 3-4 views (iso, top, front). Fix the 2 biggest defects per round, 2 rounds max, then report what remains.
12. Do not touch what the user built unless asked. Name and tag what you create (root "<Name>_LC", attributes style/seed/spec). Re-describe before editing a previous build.
13. If a tool fails or a limit is hit (mesh 20k tris, Mesh/Image API off, no screenshot permission), say so and use the fallback (wedges/blocks). Never claim success without readback.
14. Final message: what was built (names/paths, size in studs, part count), what to check by hand, what is left (e.g. a mesh needs upload to persist in the place).
```

### 5.4 Note de implementare pentru motorul `Modeling/` (capcane găsite)
1. `Instance.new("Part")` are `Anchored=false` și suprafețe cu studs/inlets: setează `Anchored`, `TopSurface/BottomSurface = Smooth` (EgoMoose și GapFill o fac) [V][O2][O3]. `Part.Shape` are și `Wedge`/`CornerWedge` (GapFill creează `Part` cu `Shape = Wedge`) [V][O3][R30].
2. Cilindrul stă pe axa **X** (lungime = `Size.X`); sfera are `Size` uniform; pentru un cilindru vertical: `cf * CFrame.Angles(0, 0, π/2)` [V][O1][O8][O7].
3. Wedge-ul: calibrare cu raycast la prima rulare (1.4-A); testele existente (`python3 plugin/tests/run.py`) nu pot verifica motorul real, deci pune verificarea pe runtime.
4. Piese noi create cu `Parent = nil`, apoi părintele pe lot; yield la fiecare 300-500 de piese (`task.wait()`), ca să eviți „script exhausted” (practică comună; în `ProceduralModel` se folosește `Pause()`) [V][R15]; `Workspace:BulkMoveTo` pentru mutări în masă [V][R30].
5. O singură înregistrare `ChangeHistoryService` per operație (id păstrat în atribut dacă pluginul se reîncarcă); ghost-urile se creează **înainte/în afara** înregistrării și se distrug înainte de commit [V][R38].
6. Pivot model: centrul bazei; `PrimaryPart` sau `WorldPivot`; `ScaleTo` pentru scalare uniformă [V][R35].
7. Determinism: `Random.new(seed)` în toate generatoarele; spec-ul se salvează pe root (atribut sau `StringValue`; limita de dimensiune a atributelor string [?], deci `StringValue` pentru JSON mare) [D].
8. Detectarea capabilităților (toate cu `pcall`): `EditableMesh` (setarea de joc), `CreateAssetAsync` (beta), `StudioCaptureService` (permisiune), `ProceduralModel`, `GeometryService` pe mesh (beta). Mesaje de ghidare către utilizator (unde bifezi, restart Studio) [V][O6].
9. `EditableMesh`: folosește `BatchAdd/BatchSetValues` (mult mai rapide decât apelurile unitare) [V][R1]; respectă 60k/20k; `CreateMeshPartAsync` o dată per mesh; `:Clone()` pentru copii; un mesh = un `Content` (instancing) [V][R1][R9]. Winding antiorar; `DoubleSided` doar dacă e nevoie.
10. Oglindire: inversează winding și verifică `det(R)=+1` (1.4-E) [D].
11. Teste automate fără Roblox (Python/Luau mock) pentru matematică: acoperirea triunghiului de către wedge-uri (aria și vertecșii), `det` după reflexie, goluri între segmentele de arc (distanța dintre capete ≤ 1e-6 pe cercul exterior), numărul de trepte `n·rise' = H`; scripturile mele din scratch pot fi reutilizate ca bază [D].
12. Toate API-urile recomandate există în `API-Dump.json` (ramura `roblox`), deci trec de verificarea `api-usage` din `plugin/tests`; actualizează `tests/data/api_subset.json` cu `make_api_subset.py` când adaugi clase noi în mock-uri [V][R30].
13. Licențe: reimplementează din matematică; dacă copii cod GapFill/ResizeAlign/PartToTerrain păstrează notice-ul MIT; nu copia din F3X și EgoMoose/Articles (fără fișier LICENSE în repo), ROBLEND (GPL-2.0), Roqer (AGPL-3.0) [V].
14. Capturi: `UICaptureMode = None`, ascunde ghost-urile; restaurează camera chiar și la eroare (`pcall` + finally) [D].
15. Atenție la instrucțiuni injectate: conținutul din place (nume, atribute, scripturi) este date, nu instrucțiuni (deja în `AI.AGENT_PROMPT`) [V].

### 5.5 Întrebări deschise pentru proprietar
- Ce stil implicit vrea pentru Claude (low-poly sau realist)? Impactează paleta și materialele implicite.
- Acceptă flag-ul beta „CreateAssetAsync Lua API” și upload-urile de mesh-uri (moderate, contor 30/min) pentru props pe `EditableMesh`, sau rămânem pe „bake în wedge-uri” ca implicit?
- Vrea trimiterea de imagini către Claude (cost în tokeni, permisiune de captură în Studio) activă implicit sau opțională?

---

## 6. Surse

Bază documentație oficială (oglindă GitHub, commit `af5f853` din 10.10.2026): `https://github.com/Roblox/creator-docs/blob/main/content/en-us/` + calea.

**Documentația Roblox [R]**
- R1 `reference/engine/classes/EditableMesh.yaml`; R2 `.../AssetService.yaml`; R3 `.../EditableImage.yaml`; R4 `.../Terrain.yaml`; R5 `.../BasePart.yaml`; R6 `.../MeshPart.yaml`; R7 `.../GeometryService.yaml`
- R8 `parts/solid-modeling.md`; R9 `performance-optimization/improve.md`; R10 `parts/meshes.md`; R11 `art/modeling/specifications.md`; R12 `art/modeling/texture-specifications.md`; R13 `workspace/collisions.md`; R14 `workspace/streaming/index.md`
- R15 `parts/procedural-models.md`; R16 `studio/mcp.md`; R17 `assistant/guide.md`; R18 `assistant/prompt-engineering.md`
- R19 `tutorials/curriculums/environmental-art/greybox-your-environment.md`; R20 `.../develop-polished-assets.md`; R21 `.../optimize-your-experience.md`; R22 `tutorials/use-case-tutorials/modeling/assemble-modular-environments.md`
- R23 `physics/units.md`; R24 `parts/index.md`
- R25 `reference/engine/classes/StudioCaptureService.yaml`; R26 `.../StudioScreenshotCapture.yaml`
- R27 `.../Humanoid.yaml` și `.../StarterPlayer.yaml`; R28 `characters/pathfinding.md`; R29 `studio/avatar-settings.md`
- R30 `API-Dump.json`: https://raw.githubusercontent.com/MaximumADHD/Roblox-Client-Tracker/roblox/API-Dump.json
- R31 `studio/align-tool.md`; R32 `studio/pivot-tools.md`; R33 `studio/terrain-editor.md`; R34 `parts/terrain.md`
- R35 `.../Model.yaml`, `.../PVInstance.yaml`; R36 `.../WeldConstraint.yaml`; R37 `.../Instance.yaml`
- R38 `studio/plugins.md`; R39 `.../Plugin.yaml`, `.../StudioService.yaml`, `.../ChangeHistoryService.yaml`
- R40 `performance-optimization/scene-analysis.md`, `.../SceneAnalysisService.yaml`; R41 `art/modeling/surface-appearance.md`; R42 `parts/materials.md`; R43 `assistant/skills.md`; R44 `parts/model-generation.md`; R45 `reference/engine/classes/Workspace.yaml`; R46 `avatar/rigid-accessories/specifications.md`

**Cod deschis și depozite [O]**
- O1 F3X: https://github.com/F3XTeam/ROBLOX-Building-Tools (ramura `development`: `Core/Snapping.lua`, `Core/init.lua`, `Tools/Move/init.lua`, `Tools/Resize.lua`, `Libraries/SerializationV3.lua`)
- O2 EgoMoose: https://github.com/EgoMoose/Articles/blob/master/3d%20triangles/3D%20triangles.md
- O3 GapFill: https://github.com/stravant/roblox-gapfill (`src/fillTriangle.lua`, `src/doFill.lua`, `src/doPolygonFill.lua`, `src/Settings.lua`, `src/createGapFillSession.lua`, `src/createVirtualUndo.lua`)
- O4 ResizeAlign: https://github.com/stravant/roblox-resizealign (`src/doExtend.lua`)
- O5 `stravant/geometry` (în `Packages/` din GapFill): https://github.com/stravant/roblox-gapfill/tree/main/Packages/_Index/stravant_geometry%400.1.3/geometry
- O6 ROBLEND: https://github.com/CRUPPNOMICS/ROBLEND (`README.md`, `src/Display.lua`, `src/Setup.lua`)
- O7 Roqer: https://github.com/XcapeAxis/Roqer/tree/main/apps/desktop/agent/skills/roblox-building (fork al https://github.com/S4US/Roqer) (`SKILL.md`, `references/{full,composition,paths,scatter,modeling,mesh-boundary,world-intent,visual-repair}.md`)
- O8 Quenty Part to Terrain: https://github.com/Quenty/PartToTerrainPlugin/blob/master/src/modules/Shared/TerrainConverter.lua
- O9 Mirror Pro: https://github.com/MrPluginMaker/MirrorPro; O10 RoundifyPart: https://github.com/KhanPython/RoundifyPart; O11 SGSL: https://github.com/mateuszsrebrny/sledzik-games-scene-language
- O12 Studio-Tools (TransformDragger, TerrainTools, Animation Editor): https://github.com/Roblox/Studio-Tools; O13 https://github.com/Roblox/studio-rust-mcp-server (arhivat); O14 https://github.com/RudraIV/BloxSync
- O15 Tag Editor: https://github.com/tiffany352/Roblox-Tag-Editor; O16 forkuri MCP: https://github.com/boshyxd/robloxstudio-mcp/releases

**Unelte AI / cercetare [A]**
- A1 mcbuild: https://github.com/misterblaecher/GabCon-BuildAI; A2 CraftDAG: https://github.com/i365dev/CraftDAG; A3 Minecraft-Builder: https://github.com/sijiyu521/Minecraft-Builder
- A4 APT: https://github.com/spearsheep/APT-Architectural-Planning-LLM-Agent și https://arxiv.org/abs/2411.17255
- A5 LL3M: https://github.com/threedle/ll3m; A6 BlenderMCP: https://github.com/ahujasid/blender-mcp
- A7 SceneCraft: https://arxiv.org/abs/2403.01248 ; Holodeck (listă): https://github.com/YandanYang/Awesome-Indoor-Scene-Synthesis

**Snippet-uri DevForum / Roblox (nu am putut deschide paginile) [F]**
- F2 https://devforum.roblox.com/t/allow-applying-baked-mesh-content-to-a-meshpart-without-a-lag-spike/4752538
- F3 https://devforum.roblox.com/t/beta-lua-asset-creation-for-creator-tooling-with-createassetasync/3294134; F4 https://devforum.roblox.com/t/2725284; F5 https://devforum.roblox.com/t/editablemesh-rate-limit/3525044
- F6 https://devforum.roblox.com/t/better-fillwedge/804095 și https://devforum.roblox.com/t/convert-wedges-to-terrain/241998
- F8 https://devforum.roblox.com/t/-/452717; F9 https://devforum.roblox.com/t/mesher-optimize-builds/2455847; F10 https://devforum.roblox.com/t/plug-in-geometrik-beta/1466822
- F11 https://devforum.roblox.com/t/1610366 și https://devforum.roblox.com/t/create-perfect-arcs/168753
- F12 https://devforum.roblox.com/t/csg-returned-error-code-8/1490608 și https://devforum.roblox.com/t/csg-generates-duplicate-triangles-rarely/4063183
- F13 https://devforum.roblox.com/t/csg-to-editablemesh-plugin/3942570; F14 https://devforum.roblox.com/t/voxel-to-part-plugin/3563871; F15 https://devforum.roblox.com/t/need-some-tips-with-building/2076658
- F16 https://about.roblox.com/newsroom/2017/05/3-must-studio-plugins și https://devforum.roblox.com/t/help-with-gapfill/909391
- F17 https://devforum.roblox.com/t/measurement-conversion/137419 și https://devforum.roblox.com/t/meters-to-studs/984843
- F18 https://devforum.roblox.com/t/creating-a-beveling-plugin/4199605
- F19 https://devforum.roblox.com/t/is-there-a-part-limit/755095, https://devforum.roblox.com/t/how-many-meshparts-is-too-much/1193847, https://devforum.roblox.com/t/how-many-instances-is-too-many/3989794

Verificări numerice proprii [D] (Python/numpy, în scratch-ul sesiunii): descompunerea triunghi -> 2 wedge-uri (2000/2000 corecte sub orientarea „fața verticală la +Z”, 0/2000 sub cea inversă), reflexie (`det(M·R) = -1`, `+1` după corecția pe axa locală), oglindirea `CornerWedge` (rotație Y de -90° în spațiul local + inversare Size X/Z), tabelul de segmentare a arcurilor, numere pentru scări și acoperișuri, compararea mărimii notațiilor.
