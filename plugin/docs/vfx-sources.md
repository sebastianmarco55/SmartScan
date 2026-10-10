# Surse VFX gratuite: texturi, ID-uri și șabloane

Ce a intrat în LostCube și de unde vine. Regula: **intră doar ce s-a putut verifica** dintr-o sursă care arată efectiv calea sau ID-ul; restul e în secțiunea [Nevrificat](#8-nevrificat).

Fișiere atinse: `plugin/LostCube/Editor/init.luau` (`Editor.TEXTURES`, `Editor.PRESETS`, `Editor.TEMPLATES`, `Editor.newFromTemplate`, `Editor.importEmitters`, `Editor.importAsset`) și `plugin/LostCube/VFXPanel.luau` (butoanele „+ Din șablon” și „Importă VFX gratuit”).

## 1. Pe scurt

| Ce | Înainte | Acum | Din care sursă verificată |
|---|---|---|---|
| Texturi (`Editor.TEXTURES`) | 11 | 34 | 2 încorporate în Roblox + 21 ID-uri din documentația oficială Roblox |
| Preseturi (`Editor.PRESETS`) | 25 | 69 | proprii (folosesc doar texturile de mai sus) |
| Șabloane (`Editor.TEMPLATES`) | 0 | 21 | proprii |

## 2. Cum am verificat și ce n-am putut verifica

Mediul în care am lucrat permite doar GitHub: `create.roblox.com`, `devforum.roblox.com`, `roblox.com`, `en.help.roblox.com` și arhivele web sunt blocate (403 / DNS). De aceea:

- **Am deschis și citit** două depozite oficiale/publice de pe GitHub (secțiunile 3 și 4).
- **N-am putut deschide** nicio pagină de Creator Store sau DevForum. Ce știm despre ele vine din rezumatele unui motor de căutare (secțiunea 7) și e marcat ca atare. **Niciun ID din ele nu a fost adăugat.**
- Adresele `create.roblox.com/docs/...` de mai jos sunt deduse din calea fișierului în depozit (așa e organizat site-ul); fișierul sursă e dat alături, ca să poată fi verificat direct pe GitHub.

Depozite folosite (stare la 2026-10-10):

| Depozit | Ce conține | Versiune verificată |
|---|---|---|
| https://github.com/MaximumADHD/Roblox-Client-Tracker (ramura `roblox`) | oglindă a conținutului Roblox Studio (liste de fișiere `textures/…`, `API-Dump.json`) | commit `41ab074bc29dd2a51a5bb17bc3498e0465842794`, Studio `0.742.0.7421053` (2026-10-07) |
| https://github.com/Roblox/creator-docs (ramura `main`) | sursa documentației oficiale Roblox (create.roblox.com/docs) | commit `af5f853c78b58c4ea86d62ac2345f881ac11fcec` |

Cu `API-Dump.json` din primul depozit am verificat și numele proprietăților, tipurile și valorile enum folosite de toate preseturile (rulate într-un mock Roblox bazat pe dump).

## 3. Texturi încorporate `rbxasset://textures/particles/…` (fără upload, fără proprietate)

**Sursă:** Roblox-Client-Tracker, folderul `textures/particles/` (28 de fișiere). Link: https://github.com/MaximumADHD/Roblox-Client-Tracker/tree/41ab074bc29dd2a51a5bb17bc3498e0465842794/textures/particles

Calea în joc este `rbxasset://textures/particles/<fișier>`. Existența fișierelor e **verificată** (listă de fișiere + conținutul lor, descărcate și privite). Că sunt livrate și cu clientul de joc (nu doar cu Studio) este **dedus**: numele corespund obiectelor clasice Roblox (Fire, Smoke, Sparkles, Explosion, ForceField), iar `sparkles_main.dds` este textura implicită a unui `ParticleEmitter` nou (documentația spune doar „white sparkle texture”). Cele 28 de fișiere:

| Fișier | În LostCube |
|---|---|
| `SquareParticle.png` | `SQUARE` (existent) |
| `common_alpha.dds` | canal auxiliar (nu e textură de sine stătătoare) |
| `explosion01_core_alpha.png` | canal auxiliar al `EXPLOSION` |
| `explosion01_core_main.dds` | `EXPLOSION` (existent) |
| `explosion01_implosion_color.png` | canal auxiliar al `GLOW` |
| `explosion01_implosion_main.dds` | `GLOW` (existent) |
| `explosion01_shockwave_main.dds` | `RING` (existent) |
| `explosion01_smoke_alpha.dds` | canal auxiliar |
| `explosion01_smoke_color_new.dds` | canal auxiliar |
| `explosion01_smoke_main.dds` | `SMOKE_SOFT` (existent) |
| `explosion_alpha.dds` | canal auxiliar (explozia veche) |
| `explosion_color.dds` | canal auxiliar (explozia veche) |
| `fire_alpha.dds` | canal auxiliar |
| `fire_color.dds` | canal auxiliar |
| `fire_main.dds` | `FIRE` (existent) |
| `fire_sparks_color.dds` | canal auxiliar |
| `fire_sparks_main.dds` | **`FIRE_SPARKS` (nou)** |
| `forcefield_alpha.dds` | canal auxiliar |
| `forcefield_glow_alpha.dds` | canal auxiliar |
| `forcefield_glow_color.dds` | canal auxiliar |
| `forcefield_glow_main.dds` | **`FORCEFIELD_GLOW` (nou)** |
| `forcefield_vortex_color.dds` | canal auxiliar |
| `forcefield_vortex_main.dds` | `CIRCLE` (existent) |
| `legacy_fire_alpha_color.dds` | canal auxiliar (focul vechi) |
| `smoke_color.dds` | canal auxiliar |
| `smoke_main.dds` | `SMOKE` (existent) |
| `sparkles_color.dds` | canal auxiliar |
| `sparkles_main.dds` | `SPARKLES` (existent) |

Concluzii:

- Nu există texturi încorporate pentru **fulger, apă, gheață, stele cu raze, zgârieturi, spirale**. Pentru ele am folosit ID-urile oficiale din secțiunea 4.
- Fișierele `*_alpha`, `*_color` sunt rampe / canale auxiliare ale obiectelor clasice, nu imagini de particulă; nu le-am adăugat (cele pe care le-am deschis: `common_alpha`, `explosion01_core_alpha`, `explosion01_implosion_color` sunt gradiente de 128×32; restul — după nume).
- **Licență / termeni:** conținut al Roblox, folosibil în Studio și în experiențele de pe Roblox; nu cere upload, nu cere proprietate, nu cere atribuire. N-am putut citi Termenii de utilizare (site blocat): nu presupune dreptul de a le scoate din Roblox.

## 4. ID-uri oficiale Roblox (din documentația oficială)

**Sursă:** Roblox/creator-docs. Fiecare ID apare în documentație, de obicei lângă imaginea texturii, ca să fie lipit în proprietatea `Texture` a unui `ParticleEmitter`. Rândurile „starter pack” sunt confirmate pe **patru pagini** cu aceleași ID-uri (`work-with-particle-emitters.md`, `education/build-it-play-it-mansion-of-wonder/using-textures.md`, `making-an-explosion.md`, `creating-a-sparkler.md`); imaginile le-am descărcat și le-am privit, descrierile „arată ca” vin din ele.

| Cheie LostCube | `rbxassetid` | Cum arată / ce e | Pagina oficială (fișier în depozit) |
|---|---|---|---|
| `STAR4` | `5860841663` | stea cu 4 raze subțiri și miez luminos | Work with particle emitters (+ 3 pagini Build It Play It, vezi mai sus) – `content/en-us/tutorials/curriculums/artist/work-with-particle-emitters.md` |
| `STAR_BURST` | `5860841737` | miez luminos cu raze lungi (stea strălucitoare) | Work with particle emitters (+ 3 pagini Build It Play It, vezi mai sus) – `content/en-us/tutorials/curriculums/artist/work-with-particle-emitters.md` |
| `STAR_SOLID` | `6772783963` | stea plină, cu colțuri rotunjite | Work with particle emitters (+ 3 pagini Build It Play It, vezi mai sus) – `content/en-us/tutorials/curriculums/artist/work-with-particle-emitters.md` |
| `SWIRL` | `5857851812` | spirală albă (vârtej) | Work with particle emitters (+ 3 pagini Build It Play It, vezi mai sus) – `content/en-us/tutorials/curriculums/artist/work-with-particle-emitters.md` |
| `RING_SOFT` | `6711256324` | inel subțire cu halou moale | Work with particle emitters (+ 3 pagini Build It Play It, vezi mai sus) – `content/en-us/tutorials/curriculums/artist/work-with-particle-emitters.md` |
| `DISC_SOFT` | `5857892330` | disc cu margini foarte moi | Work with particle emitters (+ 3 pagini Build It Play It, vezi mai sus) – `content/en-us/tutorials/curriculums/artist/work-with-particle-emitters.md` |
| `SMOKE_WISP` | `5833235272` | nor de fum ușor, estompat | Work with particle emitters (+ 3 pagini Build It Play It, vezi mai sus) – `content/en-us/tutorials/curriculums/artist/work-with-particle-emitters.md` |
| `ELECTRIC_CRACKLE` | `5833323391` | rețea de descărcări electrice (ca o minge de plasmă) | Work with particle emitters (+ 3 pagini Build It Play It, vezi mai sus) – `content/en-us/tutorials/curriculums/artist/work-with-particle-emitters.md` |
| `LIGHTNING_LINE` | `5857931724` | un fulger vertical subțire, în zigzag | Work with particle emitters (+ 3 pagini Build It Play It, vezi mai sus) – `content/en-us/tutorials/curriculums/artist/work-with-particle-emitters.md` |
| `SCRATCH` | `5857892405` | trei dungi diagonale subțiri (zgârieturi / tăietură) | Work with particle emitters (+ 3 pagini Build It Play It, vezi mai sus) – `content/en-us/tutorials/curriculums/artist/work-with-particle-emitters.md` |
| `ELECTRIC_SPARK` | `6101261905` | „electric spark texture” – așa o descrie tutorialul (imaginea nu e afișată acolo) | Create explosions with VFX – `content/en-us/tutorials/use-case-tutorials/vfx/use-particles-for-explosions.md` |
| `SOFT_CIRCLE` | `3845808160` | cerc cu margini estompate, bun pentru fum (descris în tutorial; imaginea nu e afișată) | Custom particle effects – `content/en-us/tutorials/use-case-tutorials/vfx/custom-particle-effects.md` |
| `FLARE_BIG` | `8983307836` | „flare” făcut pentru amestec aditiv, LightEmission 1 (descris în tutorial; aspectul nu l-am văzut) | Create basic visual effects – `content/en-us/tutorials/curriculums/core/building/create-basic-visual-effects.md` |
| `DUST_MOTES` | `14302399641` | particule de praf (descris în tutorial; aspectul nu l-am văzut) | Create basic visual effects – `content/en-us/tutorials/curriculums/core/building/create-basic-visual-effects.md` |
| `CLOUD` | `10714362544` | imagine de nor (descris în tutorial; aspectul nu l-am văzut) | Construct your world – `content/en-us/tutorials/curriculums/environmental-art/construct-your-world.md` |
| `SPLASH_DENSE` | `16829556885` | explozie densă de stropi albi | Create waterfalls with VFX – `content/en-us/tutorials/use-case-tutorials/vfx/create-waterfalls.md` |
| `DROPLETS` | `17082061238` | nor de picături fine | Create waterfalls with VFX – `content/en-us/tutorials/use-case-tutorials/vfx/create-waterfalls.md` |
| `WHITEWATER` | `16808075391` | stropi în formă de plasă (apă albă) | Create waterfalls with VFX – `content/en-us/tutorials/use-case-tutorials/vfx/create-waterfalls.md` |
| `FOAM_RING` | `16811365086` | spumă / inel de ondulații, cu centrul gol | Create waterfalls with VFX – `content/en-us/tutorials/use-case-tutorials/vfx/create-waterfalls.md` |
| `MIST` | `16830667309` | ceață / abur gros | Create waterfalls with VFX – `content/en-us/tutorials/use-case-tutorials/vfx/create-waterfalls.md` |
| `EMBERS` | `17581858560` | ovale alungite luminoase (jar) | Create volcanic eruptions with VFX – `content/en-us/tutorials/use-case-tutorials/vfx/create-volcanoes.md` |

Paginile (adrese deduse din cale): Work with particle emitters: https://create.roblox.com/docs/tutorials/curriculums/artist/work-with-particle-emitters; Create explosions with VFX: https://create.roblox.com/docs/tutorials/use-case-tutorials/vfx/use-particles-for-explosions; Custom particle effects: https://create.roblox.com/docs/tutorials/use-case-tutorials/vfx/custom-particle-effects; Create basic visual effects: https://create.roblox.com/docs/tutorials/curriculums/core/building/create-basic-visual-effects; Construct your world: https://create.roblox.com/docs/tutorials/curriculums/environmental-art/construct-your-world; Create waterfalls with VFX: https://create.roblox.com/docs/tutorials/use-case-tutorials/vfx/create-waterfalls; Create volcanic eruptions with VFX: https://create.roblox.com/docs/tutorials/use-case-tutorials/vfx/create-volcanoes.

**Licență / termeni:**

- Sunt ID-uri publicate de Roblox chiar în tutorialele oficiale, cu instrucțiunea de a le lipi în proiectul tău. Documentația nu cere atribuire pentru ele.
- Textul și imaginile documentației sunt sub CC BY 4.0 (fișierul `LICENSE` din depozit); asta privește documentația, nu e o licență separată pentru imaginile încărcate pe Roblox.
- Creator Store este descris oficial ca magazin de active „made by Roblox and independent creators” (`content/en-us/production/creator-store.md`); imaginile, decalurile și mesh-urile sunt **Open Use** implicit (orice creator/joc le poate folosi), iar un asset Restricted nu se încarcă fără permisiune (`content/en-us/projects/assets/privacy.md`). **Nu am putut verifica pe pagina fiecărui asset că e Open Use.** Dacă o textură nu se încarcă, Output arată o eroare de permisiuni: înlocuiește-o.
- Imaginile „starter pack” sunt afișate în documentație ca RGB fără alpha (negru = fundal); pe particule folosește `LightEmission = 1` (cum fac preseturile) ca negrul să dispară. Cele din tutorialele cu apă / foc au alpha.
- Mai multe texturi ocupă doar centrul imaginii (≈ 50 % din lățime la stele, zgârieturi și spirală): mărimile din preseturi țin cont de asta (Size ≈ dublul aspectului dorit).

## 5. Ce a adăugat LostCube

### 5.1 Texturi noi (`Editor.TEXTURES`, cheile vechi nu s-au schimbat)

Grupele apar ca anteturi în lista „Textură” din panou.

| Cheie | Etichetă | URL | Grup |
|---|---|---|---|
| `FIRE_SPARKS` | Jar mărunt (puncte de foc) | `rbxasset://textures/particles/fire_sparks_main.dds` | Încorporate în Roblox (fără upload) |
| `FORCEFIELD_GLOW` | Aură difuză (forcefield) | `rbxasset://textures/particles/forcefield_glow_main.dds` | Încorporate în Roblox (fără upload) |
| `STAR4` | Stea cu 4 raze | `rbxassetid://5860841663` | Roblox oficial (ID-uri din tutoriale) |
| `STAR_BURST` | Stea strălucitoare (cu raze) | `rbxassetid://5860841737` | Roblox oficial (ID-uri din tutoriale) |
| `STAR_SOLID` | Stea plină | `rbxassetid://6772783963` | Roblox oficial (ID-uri din tutoriale) |
| `SWIRL` | Spirală / vârtej | `rbxassetid://5857851812` | Roblox oficial (ID-uri din tutoriale) |
| `RING_SOFT` | Inel moale | `rbxassetid://6711256324` | Roblox oficial (ID-uri din tutoriale) |
| `DISC_SOFT` | Disc moale | `rbxassetid://5857892330` | Roblox oficial (ID-uri din tutoriale) |
| `SMOKE_WISP` | Fum (nor ușor) | `rbxassetid://5833235272` | Roblox oficial (ID-uri din tutoriale) |
| `ELECTRIC_CRACKLE` | Descărcare electrică (rețea) | `rbxassetid://5833323391` | Roblox oficial (ID-uri din tutoriale) |
| `LIGHTNING_LINE` | Fulger (linie) | `rbxassetid://5857931724` | Roblox oficial (ID-uri din tutoriale) |
| `SCRATCH` | Zgârieturi (tăietură) | `rbxassetid://5857892405` | Roblox oficial (ID-uri din tutoriale) |
| `ELECTRIC_SPARK` | Scântei electrice | `rbxassetid://6101261905` | Roblox oficial (ID-uri din tutoriale) |
| `SOFT_CIRCLE` | Cerc cu margini moi | `rbxassetid://3845808160` | Roblox oficial (ID-uri din tutoriale) |
| `FLARE_BIG` | Flare mare (lumină aditivă) | `rbxassetid://8983307836` | Roblox oficial (ID-uri din tutoriale) |
| `DUST_MOTES` | Particule de praf | `rbxassetid://14302399641` | Roblox oficial (ID-uri din tutoriale) |
| `CLOUD` | Nor mare | `rbxassetid://10714362544` | Roblox oficial (ID-uri din tutoriale) |
| `SPLASH_DENSE` | Stropi denși de apă | `rbxassetid://16829556885` | Roblox oficial (ID-uri din tutoriale) |
| `DROPLETS` | Picături fine | `rbxassetid://17082061238` | Roblox oficial (ID-uri din tutoriale) |
| `WHITEWATER` | Apă spumoasă (plasă) | `rbxassetid://16808075391` | Roblox oficial (ID-uri din tutoriale) |
| `FOAM_RING` | Spumă (inel de ondulații) | `rbxassetid://16811365086` | Roblox oficial (ID-uri din tutoriale) |
| `MIST` | Ceață / abur | `rbxassetid://16830667309` | Roblox oficial (ID-uri din tutoriale) |
| `EMBERS` | Jar (scântei alungite) | `rbxassetid://17581858560` | Roblox oficial (ID-uri din tutoriale) |

### 5.2 Preseturi noi (`Editor.PRESETS`, câmpul nou `group`)

Meniul „+ Adaugă element” este grupat pe teme; pictograma arată tipul (★ particule, ■ mesh 3D, ≈ trail, ☀ lumină). Cele 25 existente au primit doar un `group`, comportamentul lor nu s-a schimbat.

| Cheie | Tip | Grup | Etichetă | Textură |
|---|---|---|---|---|
| `ELECTRIC_SPARKS` | PARTICLES | Electricitate | Scântei electrice | `ELECTRIC_SPARK` |
| `ELECTRIC_ARC` | PARTICLES | Electricitate | Arcuri electrice (fulgere scurte) | `LIGHTNING_LINE` |
| `LIGHTNING_BOLT` | PARTICLES | Electricitate | Trăznet vertical | `LIGHTNING_LINE` |
| `ELECTRIC_CRACKLE` | PARTICLES | Electricitate | Descărcări electrice (continuu) | `ELECTRIC_CRACKLE` |
| `WATER_SPLASH` | PARTICLES | Apă și gheață | Stropi de apă (splash) | `SPLASH_DENSE` |
| `WATER_DROPLETS` | PARTICLES | Apă și gheață | Picături de apă | `DROPLETS` |
| `WATER_RING` | PARTICLES | Apă și gheață | Ondulații pe apă (inel) | `FOAM_RING` |
| `FROST_MIST` | PARTICLES | Apă și gheață | Ceață rece (la sol) | `MIST` |
| `FROST_SPARKLE` | PARTICLES | Apă și gheață | Cristale care sclipesc | `STAR4` |
| `SNOWFALL` | PARTICLES | Apă și gheață | Fulgi care cad | `SOFT_CIRCLE` |
| `ICE_SHARDS` | MESH | Apă și gheață | Cioburi de gheață (3D) | – |
| `ICE_CRACKS` | MESH | Apă și gheață | Crăpături de gheață (pe sol) | – |
| `WATER_DROPS3D` | MESH | Apă și gheață | Picături 3D (cad cu fizică) | – |
| `ICE_LIGHT` | LIGHT | Lumini | Lumină rece (gheață) | – |
| `HEAL_MOTES` | PARTICLES | Vindecare și lumină | Sclipiri verzi care urcă | `STAR4` |
| `HEAL_RING` | PARTICLES | Vindecare și lumină | Inel care urcă (scanare) | `RING_SOFT` |
| `HOLY_FLARE` | PARTICLES | Vindecare și lumină | Flare sfânt (stea mare) | `STAR_BURST` |
| `HOLY_PILLAR` | MESH | Vindecare și lumină | Coloană de lumină | – |
| `HEAL_LIGHT` | LIGHT | Lumini | Lumină verde (vindecare) | – |
| `HOLY_LIGHT` | LIGHT | Lumini | Lumină sfântă (aurie) | – |
| `DARK_SMOKE` | PARTICLES | Întuneric și otravă | Fum întunecat (energie) | `SMOKE_SOFT` |
| `DARK_WISPS` | PARTICLES | Întuneric și otravă | Aburi violet (energie) | `SMOKE_WISP` |
| `POISON_BUBBLES` | PARTICLES | Întuneric și otravă | Bule otrăvitoare | `RING_SOFT` |
| `POISON_CLOUD` | PARTICLES | Întuneric și otravă | Nor toxic | `SMOKE` |
| `HIT_SPARK` | PARTICLES | Luptă | Scântei de lovitură (dungi) | `GLOW` |
| `SLASH_MARK` | PARTICLES | Luptă | Tăietură (urmă de lamă) | `SCRATCH` |
| `SLASH_TRAIL` | TRAIL | Luptă | Dâră de sabie (în mână) | `GLOW` |
| `SPEED_LINES` | PARTICLES | Mișcare | Linii de viteză (în spate) | `GLOW` |
| `AIR_RING` | PARTICLES | Mișcare | Inel de aer (în spate) | `RING_SOFT` |
| `DASH_WIND` | PARTICLES | Mișcare | Vânt (fum în spate) | `SMOKE_WISP` |
| `DASH_TRAIL` | TRAIL | Mișcare | Dâră de viteză | `GLOW` |
| `LAND_DUST` | PARTICLES | Mișcare | Praf la aterizare (greu) | `SMOKE_SOFT` |
| `PORTAL_SWIRL` | PARTICLES | Mișcare | Vârtej de portal (pe sol) | `SWIRL` |
| `PORTAL_STANDING` | PARTICLES | Mișcare | Portal vertical (în față) | `SWIRL` |
| `COLUMN_STREAKS` | PARTICLES | Mișcare | Raze verticale (coloană) | `GLOW` |
| `FIREBALL` | PARTICLES | Foc, fum și praf | Minge de foc (explozie) | `EXPLOSION` |
| `EMBERS` | PARTICLES | Foc, fum și praf | Jar care zboară | `EMBERS` |
| `FIRE_LIGHT` | LIGHT | Lumini | Lumină de foc (se stinge) | – |
| `ELECTRIC_LIGHT` | LIGHT | Lumini | Lumină electrică (pâlpâie) | – |
| `CONFETTI` | PARTICLES | Sărbătoare | Confetti | `SQUARE` |
| `COINS_BURST` | MESH | Sărbătoare | Monede (explozie 3D) | – |
| `SHIELD_AURA` | PARTICLES | Scut și aură | Scut: contur luminos (urmărește) | `RING_SOFT` |
| `SHIELD_GLOW` | PARTICLES | Scut și aură | Scut: strălucire interioară (urmărește) | `GLOW` |
| `SHIELD_BUBBLE` | MESH | Scut și aură | Bulă de scut (ForceField) | – |

Note de funcționare (limite ale player-ului, nu ale presetului):

- Piesele **3D** (mesh) ale efectelor rămân pe loc: sunt ancorate unde apar. Pentru efecte care trebuie să urmărească un personaj (scut, aure) șabloanele folosesc **particule cu `LockedToPart`** (`SHIELD_AURA`, `SHIELD_GLOW`).
- Un `Trail` se vede doar când atașamentele lui se mișcă: `SLASH_TRAIL` și `DASH_TRAIL` merg când efectul e prins de mână / personaj (`RIGHT_HAND`, `ROOT`) și acesta se mișcă.

### 5.3 Șabloane (`Editor.TEMPLATES`)

Fiecare: `{ key, label, category, desc, duration, attach, main, elements = { { preset = KEY, props = {…} } } }`. `main` este culoarea eroului efectului (ce înlocuiește recolorarea).

**Luptă**

| Cheie | Nume | Durată | Prins de | Elemente (preseturi) |
|---|---|---|---|---|
| `PUNCH` | Lovitură de pumn | 0.5 s | `TORSO` | `FLASH`, `STAR_FLASH`, `HIT_SPARK`, `AIR_RING`, `SMOKE`, `FLASH_LIGHT` |
| `SLASH` | Tăietură de sabie | 0.6 s | `TORSO` | `SLASH_MARK` ×2, `HIT_SPARK` ×2, `STAR_FLASH`, `FLASH_LIGHT` |
| `SWORD_TRAIL` | Dâră de sabie | 0.7 s | `RIGHT_HAND` | `SLASH_TRAIL` ×2, `MOTES` |
| `GROUND_SLAM` | Ground Slam | 1.1 s | `GROUND` | `SHOCKWAVE`, `RING3D`, `CRACK3D`, `DEBRIS3D`, `LAND_DUST`, `STREAKS`, `FLASH`, `DOME3D`, `FLASH_LIGHT` |

**Elemente**

| Cheie | Nume | Durată | Prins de | Elemente (preseturi) |
|---|---|---|---|---|
| `LIGHTNING` | Fulger | 1 s | `GROUND` | `LIGHTNING_BOLT`, `FLASH`, `ELECTRIC_ARC`, `ELECTRIC_SPARKS`, `SHOCKWAVE`, `SMOKE`, `CRACK3D`, `ELECTRIC_LIGHT` |
| `FIRE_EXPLOSION` | Explozie de foc | 1.3 s | `GROUND` | `FIREBALL`, `FLASH`, `SHOCKWAVE`, `EMBERS`, `SMOKE`, `DEBRIS3D`, `DOME3D`, `FIRE_LIGHT` |
| `FREEZE` | Înghețare | 2 s | `GROUND` | `ICE_CRACKS`, `ICE_SHARDS`, `FROST_MIST`, `FROST_SPARKLE`, `SNOWFALL`, `SHOCKWAVE`, `FLASH`, `ICE_LIGHT` |
| `POISON` | Otrăvire | 2.2 s | `GROUND_FOLLOW` | `POISON_CLOUD`, `POISON_BUBBLES`, `DARK_WISPS`, `WATER_DROPS3D`, `SHOCKWAVE`, `GLOW_LIGHT` |
| `WATER_SPLASH` | Splash de apă | 1.2 s | `GROUND` | `WATER_RING`, `WATER_SPLASH`, `WATER_DROPLETS`, `WATER_DROPS3D`, `FROST_MIST` |
| `DARK_ENERGY` | Energie întunecată | 2.4 s | `GROUND_FOLLOW` | `DARK_SMOKE`, `DARK_WISPS`, `PORTAL_SWIRL`, `SHOCKWAVE`, `GLOW_LIGHT` |

**Suport**

| Cheie | Nume | Durată | Prins de | Elemente (preseturi) |
|---|---|---|---|---|
| `HEAL` | Vindecare | 1.8 s | `GROUND_FOLLOW` | `MAGIC_CIRCLE`, `HEAL_RING`, `HEAL_MOTES`, `FLASH`, `HEAL_LIGHT` |
| `POWER_AURA` | Aură de putere (loop) | 3 s | `GROUND_FOLLOW` | `COLUMN_STREAKS`, `FIRE`, `RISING`, `SHOCKWAVE`, `GLOW_LIGHT` |
| `SHIELD` | Scut | 2.2 s | `ROOT` | `SHIELD_AURA`, `SHIELD_GLOW`, `SHIELD_BUBBLE`, `SPARKLES`, `SHOCKWAVE`, `GLOW_LIGHT` |
| `HOLY_RAY` | Rază sfântă | 1.8 s | `GROUND` | `HOLY_PILLAR`, `HOLY_FLARE`, `HEAL_MOTES`, `MAGIC_CIRCLE`, `HOLY_LIGHT` |

**Mișcare**

| Cheie | Nume | Durată | Prins de | Elemente (preseturi) |
|---|---|---|---|---|
| `TELEPORT` | Teleport | 1.4 s | `GROUND` | `MAGIC_CIRCLE`, `PORTAL_SWIRL`, `COLUMN_STREAKS`, `IMPLOSION`, `FLASH`, `STAR_FLASH`, `SHOCKWAVE`, `SPARKLES`, `FLASH_LIGHT` |
| `DASH` | Dash | 0.6 s | `ROOT` | `SPEED_LINES`, `AIR_RING`, `DASH_WIND`, `DASH_TRAIL`, `LAND_DUST` |
| `LANDING` | Aterizare | 0.7 s | `GROUND` | `LAND_DUST`, `SHOCKWAVE`, `CRACK3D`, `DEBRIS3D`, `PUFF3D` |
| `PORTAL` | Portal | 3 s | `GROUND` | `PORTAL_STANDING` ×2, `MAGIC_CIRCLE`, `MOTES`, `GLOW_LIGHT` |

**Evenimente**

| Cheie | Nume | Durată | Prins de | Elemente (preseturi) |
|---|---|---|---|---|
| `LEVEL_UP` | Level Up | 2.2 s | `GROUND_FOLLOW` | `HOLY_PILLAR`, `MAGIC_CIRCLE`, `COLUMN_STREAKS`, `HEAL_MOTES`, `HOLY_FLARE`, `RING3D`, `SPARKLES`, `HOLY_LIGHT` |
| `COINS` | Monede (recompensă) | 1.8 s | `GROUND_FOLLOW` | `COINS_BURST`, `STAR_FLASH`, `SPARKLES`, `HOLY_LIGHT` |
| `CONFETTI` | Confetti | 2.2 s | `GROUND` | `CONFETTI` ×3, `STAR_FLASH`, `SPARKLES` |

## 6. API nou și folosire

```lua
local Editor = require(game.ReplicatedStorage.LostCube.Editor)

-- efect complet dintr-un șablon, într-un singur pas de Ctrl+Z
local fx = Editor.newFromTemplate("Foc mare", "FIRE_EXPLOSION", { color = Color3.fromRGB(80, 160, 255), scale = 1.5 })
Editor.preview(fx)

-- VFX gratuit din Creator Store: scripturile se șterg înainte de orice, apoi emitoarele devin elemente LostCube
local model, report = Editor.importAsset(123456789, "Vrajă importată")
print(table.concat(report.lines, "\n"))

-- emitoare dintr-un model deja inserat în scenă, într-un efect existent
local info = Editor.importEmitters(fx, workspace.ModelGratuit)
print(info.particles, info.trails, info.lights, info.skipped)
```

- `Editor.newFromTemplate(name, templateKey, opts?) -> Model`: `opts.color` (Color3) înlocuiește culoarea principală a șablonului în toate elementele (nuanța se mută cu același unghi pentru toate culorile, deci accentele își păstrează relația; albul, grii și negrul rămân); `opts.scale` (0.05–20) înmulțește mărimile, distanțele și vitezele; `opts.attach` / `opts.duration` le înlocuiesc pe ale șablonului. Numele e tăiat de spații, trebuie să fie nenul, ≤ 100 de caractere și liber; la orice eroare nu rămâne nimic creat.
- `Editor.importEmitters(effect, source, opts?)`: copiază `ParticleEmitter`, `Trail`, `PointLight` și `SpotLight` (ca lumină punctuală) găsite sub `source`, cu proprietățile (Texture, Color, Size, Transparency, Squash, Lifetime, Speed, SpreadAngle, Rate, Acceleration, Drag, LightEmission, LightInfluence, Brightness, Rotation, RotSpeed, Orientation, ZOffset, LockedToPart, EmissionDirection, ShapeStyle/InOut, Flipbook…), păstrând pozițiile relative la pivotul sursei (și forma / rotația părții pe care sta emitorul). **Nu copiază niciodată scripturi.** Întoarce `{ elements, particles, trails, lights, skipped, notes }`.
  - Timp: atributele `EmitCount`, `EmitDelay`, `EmitDuration` (folosite de multe pachete VFX) se respectă; altfel un emitor activat primește fereastră de emisie 0–2 s, iar unul dezactivat (pornit de un script în original) un burst la t = 0 cu `Rate` particule (1–60; 10 dacă `Rate` e 0). Asta e o presupunere și apare în raport.
  - Limite: maxim 80 de elemente per import; `Beam`, `Fire`, `Smoke`, `Sparkles`, `Explosion` nu se importă (se numără în raport).
- `Editor.importAsset(assetId, effectName) -> (Model?, report)`: încarcă modelul cu `game:GetObjects("rbxassetid://" .. id)` (în `pcall`; dacă eșuează, `InsertService:LoadAsset`), **șterge toate `Script`, `LocalScript`, `ModuleScript` înainte de orice altceva** (și citește textul fiecăruia, fără să-l ruleze, ca să semnaleze `require(ID)`, `loadstring`, `getfenv`, `setfenv`, `HttpService`, `MarketplaceService`), creează efectul, apoi distruge modelul încărcat. `report = { ok, error?, assetId, scriptsRemoved, scriptsByClass, suspicious, particles, trails, lights, skipped, notes, analyzer?, lines }`; `lines` e raportul gata de afișat. Dacă există un modul `Analyzer` lângă `Editor`, se apelează `Analyzer.scanInstance(model)` (în `pcall`) și observațiile intră în raport. Un asset fără niciun emitor nu creează nimic.

**Siguranță:** un model gratuit cu scripturi poate conține backdoor. Importul nu rulează nimic din model (nu e pus în scenă; scripturile se șterg înainte). Raportul spune câte scripturi au fost șterse și dacă vreunul avea cod suspect; în acest caz nu folosi modelul original în joc, chiar dacă efectul importat e curat.

## 7. Surse comunitare și Creator Store (NEVERIFICATE)

Apar în rezultatele unei căutări web; **paginile n-au putut fi deschise**, deci licențele de mai jos sunt doar ce spun rezumatele și trebuie citite pe pagină înainte de folosire. Niciun ID din ele nu e în LostCube.

| Resursă | Adresă | Ce se spune în rezumatul căutării |
|---|---|---|
| Creator Store › Visual Effects › Particle Effects | https://create.roblox.com/store/category/visual-effects/particle-effects | categoria oficială de efecte de particule; fiecare asset are pagina lui cu creator și descriere |
| „Free VFX Pack” de @synmade (Creator Store) | căutați pe Creator Store | menționat ca pachet gratuit; licența nu apare |
| Yuruzuu’s Open Source VFX | https://devforum.roblox.com/t/yuruzuus-open-source-vfx/1840021 | VFX gratuite pentru jocuri; autorul *cere* credit dar nu îl impune; nu trebuie să spui că le-ai făcut tu |
| 2 Free Realistic Flipbook Particle Explosions | https://devforum.roblox.com/t/2-free-realistic-flipbook-particle-explosions/3035597 | „fără restricții”; listează linkuri Roblox pentru sprite sheet-uri (flipbook: necesită `FlipbookLayout`) |
| Free to use cartoon particle effects | https://devforum.roblox.com/t/free-to-use-cartoon-particle-effects/244195 | .rbxm din 2019 cu foc, fum, zăpadă, ploaie, grindină; gratuit, fără credit; poate fi depășit |
| Over 600 Free Particle with CIX Library | https://devforum.roblox.com/t/over-600-free-particle-with-cix-library-a-particle-library-plugin/2864815 | plugin cu texturi „open source”; autorul menționează artiști, deci verifică licența fiecărei texturi |
| SteakParticles | https://devforum.roblox.com/t/steakparticles-plugin-for-creating-vfx-and-particle-emitters/2908779 | plugin pentru VFX; licența texturilor necunoscută |
| Looking for a good texture pack specifically for auras | https://devforum.roblox.com/t/looking-for-a-good-texture-pack-specifically-for-auras/2972639 | fir cu recomandări („Jams Pro Beam Pack”, „Shuangs Stolen Textures”); licență neconfirmată (numele „Stolen” sugerează prudență) |
| Finding Particle Emitter Textures / Finding Good Particle Textures / Textures for particle effects? | https://devforum.roblox.com/t/finding-particle-emitter-textures/563306 , https://devforum.roblox.com/t/finding-good-particle-textures/884936 , https://devforum.roblox.com/t/textures-for-particle-effects/472340 | discuții despre unde găsești texturi; un răspuns spune că funcționează doar texturile încărcate de tine sau de grupul tău (vechi, anecdotic: azi imaginile sunt Open Use implicit, vezi secțiunea 4) |

**Cum adaugi o sursă nouă corect:** deschide pagina, citește licența și cere atribuire dacă e cazul; verifică în Studio că ID-ul se încarcă fără eroare de permisiuni; notează aici adresa și condițiile; abia apoi adaugă `{ key, label, url = docs(ID), group }` în `Editor.TEXTURES`. Pentru un model întreg folosește „Importă VFX gratuit” din tab-ul VFX (sau `Editor.importAsset`).

## 8. Nevrificat

Lăsat deliberat pe dinafară. Fiecare poate fi adăugat după ce se verifică ce scrie.

**Căi `rbxasset://textures/…` care există în conținutul Studio dar nu s-au putut confirma pentru clientul de joc** (Roblox-Client-Tracker oglindește Studio; singurele folosiri găsite în scripturi sunt ale pluginurilor Studio). Dacă lipsesc din client, particulele nu s-ar vedea în joc, de aceea nu sunt în `Editor.TEXTURES`:

`textures/sparkle.png` (stea cu 8 raze, 32×32), `textures/explosion.png` (nor plin, 128×128), `textures/glow.png` (halou pătrat), `textures/whiteCircle.png`, `textures/smallWhiteCircle.png`, `textures/triangle.png`, `textures/gradient.png`, `textures/noise.dds`, `textures/sky/white.png`.

**ID-uri din documentația oficială neadăugate:**

| ID | De ce nu |
|---|---|
| `5857851618` (inimă / triunghi) | documentația îl pune sub **două imagini diferite** (inimă și triunghi) pe toate cele patru pagini; nu se știe care e |
| `17363668312`, `17363669906` (volcanoes: „webby splash”, „dense splash”) | imaginile arată ca foi flipbook (grilă de cadre): au nevoie de `FlipbookLayout`, pe care elementele LostCube nu-l expun; în pagină și textul are o greșeală (`rbxassetid:/17363669906`) |
| pagina **volcanoes** (spumă `16829556885`, fum `16830673704`) | pagina volcanoes pune ID-uri diferite în legendă și în pas (spumă: 16811365086 în legendă vs 16829556885 în pas; fum: 16830667309 vs 16830673704). Texturile de apă, spumă și ceață din LostCube vin din **create-waterfalls**, unde legenda și pasul coincid; `16830673704` rămâne necunoscut |
| `16828911033` (curcubeu), `17023930265` (crustă de lavă), `16808804567` (apă curgătoare), `4787437624` (spumă curgătoare), `6060542021` (rază laser) | făcute pentru `Beam` / suprafețe, nu pentru particule; nu le-am încercat |
| ID-urile `meshId` / imagini UI din tutoriale | alt scop |

**Alte lucruri nevăzute / nepuse la încercare:**

- Aspectul `ELECTRIC_SPARK`, `SOFT_CIRCLE`, `FLARE_BIG`, `DUST_MOTES`, `CLOUD`: documentația le descrie, dar nu arată imaginea; preseturile care le folosesc (`ELECTRIC_SPARKS`, `SNOWFALL`) sunt reglate după descriere; `FLARE_BIG`, `DUST_MOTES` și `CLOUD` nu sunt folosite de niciun preset (stau doar în lista de texturi).
- Efectele nu au fost rulate în Roblox Studio (nu există aici); temporizarea și mărimile sunt calculate din proprietățile verificate. Verifică-le cu „▶ Redă” și ajustează.
- Faptul că fiecare ID din secțiunea 4 e Open Use pentru **orice** experiență (verificat doar indirect, prin faptul că tutorialele îl dau tuturor).
- Termenii de utilizare Roblox pentru conținutul `rbxasset://` și pentru active Roblox în afara platformei.

## Sunete incluse în client (adăugate în 2.1.0)
Sursă: `rbxManifest.txt` din MaximumADHD/Roblox-Client-Tracker (versiunea 0.742.0.7421053), secțiunea `content\sounds`.
Sunt fișiere ale clientului Roblox (`rbxasset://sounds/...`): nu se încarcă și nu au proprietar, deci merg în orice joc.
`Editor.SOUNDS`: action_jump_land.mp3 (HIT), impact_explosion_03.mp3 (EXPLOSION), action_falling.ogg (WIND),
action_jump.mp3 (JUMP), impact_water.mp3 (SPLASH), action_swim.mp3 (SWIM), action_get_up.mp3 (GET_UP),
action_footsteps_plastic.mp3 (STEPS), oof.ogg (OOF), ouch.ogg (OUCH), volume_slider.ogg (TICK).
Clientul nu are un sunet „magic”; pentru efecte magice folosește un ID propriu (`rbxassetid://…`).
