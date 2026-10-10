# LostCube 2.0 – plugin Roblox Studio

Pluginul își cunoaște jocul: la prima deschidere îl analizează complet, apoi te ajută cu efecte VFX,
animații gratuite și cu Claude, care are tot contextul jocului.

## Instalare
1. `python3 plugin/build.py` (sau folosește direct `plugin/LostCube.rbxmx`)
2. În Studio: **Plugins → Plugins Folder**, copiază `LostCube.rbxmx` acolo, repornește Studio.
3. Butonul **LostCube** din toolbar deschide panoul.
4. În tab-ul **◆ Claude → Module în joc** apasă „Instalează / actualizează modulele”, ca efectele să meargă și în joc
   (jocurile cu module mai vechi de 2.0.0 primesc automat banner-ul de actualizare).

## Tab-uri
| Tab | Ce face |
|---|---|
| **🧠 Joc** | Analiza jocului. La prima deschidere într-un place pornește singură și o salvează în place (`ServerStorage.LostCubeAnalysis`, nu ajunge la jucători). Ghicește genul, citește codul (framework-uri, remote-uri, API-uri depreciate), caută **backdoor-uri** din modele gratuite (`require(id)`, `loadstring`, `getfenv`, webhook-uri, cod obfuscat), probleme de performanță, efectele și animațiile existente, paleta de culori a hărții. Click pe o problemă deschide scriptul la linia exactă. Butonul „Analiză cu Claude” trimite contextul la Claude și salvează răspunsul. |
| **✨ VFX** | Editor de efecte cu previzualizare live. **21 de șabloane** complete (pumn, sabie, Ground Slam, fulger, explozie, vindecare, teleport, dash, aură, scut, înghețare, level up…) recolorabile, **69 de preseturi**, **34 de texturi** din surse oficiale Roblox, import sigur de VFX gratuite din Creator Store (după ID; toate scripturile modelului sunt șterse înainte de orice). |
| **🎬 Anim** | Previzualizare de animații pe rig în Edit mode, easing ca în Moon, efecte pe markere, plus **22 de animații generate prin cod** (combo-uri, sabie, magie, reacții, emote) pentru R6 și R15. Sunt ale tale: se salvează în `ServerStorage.RBX_ANIMSAVES`, le deschizi în Animation Editor și le publici pe contul / grupul jocului. |
| **📚 Lib** | **258 de animații gratuite deținute de Roblox** (17 pachete: Mage, Ninja, Robot, Zombie, Superhero…, plus seturile implicite și 39 de emote). Previzualizare, „Verifică proprietarul”, adăugare în joc ca `Animation` sau ca set implicit pentru toate personajele. |
| **◆ Claude** | Chat cu Claude care știe jocul (din analiză) și API-ul LostCube, cheie API, modulele din joc, istoricul acțiunilor. |

## Claude în plugin
- Ai nevoie de o cheie API de la console.anthropic.com. **Cererile costă bani din contul tău.**
- Cheia stă doar în setările pluginului pe calculatorul tău (`plugin:SetSetting`), **niciodată în place**.
- La prima cerere Studio întreabă dacă pluginul are voie să acceseze `api.anthropic.com`: apasă Allow
  (se poate schimba din Plugins → Manage Plugins).
- Model implicit Claude Opus 5.5; Sonnet 5.5 / Haiku 5.5 sunt mai rapide și mai ieftine.
- Dacă o analiză lungă dă „Timedout”, alege efortul „Rapid” sau Sonnet.
- Claude din Studio (prin MCP) poate citi și el analiza: `ServerStorage.LostCubeAnalysis.Context`.

## Utilizare rapidă
- **Ctrl + rotiță** pe un câmp numeric schimbă valoarea (Shift = ×10); rotița simplă doar derulează.
- Ține mouse-ul pe un buton sau câmp ca să vezi indiciul.
- Scurtături: *File → Advanced → Customize Shortcuts*, caută „LostCube” (redă efectul / oprește previzualizarea).
- În joc: `require(ReplicatedStorage.LostCube.VFX).play("Nume", personaj)`; `VFX.bindMarkers(track, personaj, { Hit = "Nume" })`.

## Surse gratuite
- VFX: `docs/vfx-sources.md` – texturi built-in verificate în oglinda clientului Roblox și ID-uri oficiale din
  tutorialele Roblox; resursele comunității sunt listate separat ca neverificate.
- Animații: `docs/animation-sources.md` – ID-uri confirmate în cel puțin 2 surse independente; proprietarul se
  verifică live din panou („Verifică proprietarul”), fiindcă site-urile Roblox nu erau accesibile la construire.

## Structură
- `LostCube/` – sursele Luau (`init.server.luau` = Script, restul ModuleScript-uri)
  - `Editor/` – efecte (folosit de panouri, de Claude și în joc); `Editor/VFX.luau` – player-ul din joc
  - `Analyzer` – analiza jocului; `AI` + `Markdown` – Claude; `AnimGen` – animații generate; `AnimLibrary` – animații Roblox
  - `App`, `UI`, `*Panel`, `Installer` – interfața
- `build.py` – împachetează sursele în `LostCube.rbxmx`

## Limitări cunoscute
Nimic din 2.0 nu a rulat încă în Studio; codul a trecut analiza statică Luau, teste pe API-uri simulate și un
review pe baza dump-ului oficial de API Roblox. De verificat la prima folosire:
- timpul maxim al unei cereri HTTP din Studio (analizele lungi cu Opus);
- că Animation Editor vede animațiile generate în `RBX_ANIMSAVES`;
- aspectul real al șabloanelor VFX și al animațiilor generate (dimensiuni, ritm).

## Istoric
- **2.0.0** – analiza jocului la prima deschidere, Claude în plugin, bibliotecă de animații Roblox, generator de
  animații, șabloane VFX, import sigur de VFX gratuite, 5 tab-uri.
- **1.6.0** – reparații în player (scalare dublă la Mesh 3D, efecte tăiate la viteză > 1, Trail-uri și lumini),
  indicii la hover, Ctrl + rotiță, buton ⏹, scurtături, starea panoului păstrată.
- **1.5.1** – secțiuni pliabile, instalare sigură, duplicare completă, nume unice.
