# Teste LostCube

Testele rulează **fără Roblox Studio**: codul real din `plugin/LostCube/` este executat de CLI-ul Luau într-un Roblox
simulat (mockuri), plus verificări statice. Nimic din `plugin/LostCube/` nu este copiat.

## Rulare

```
python3 plugin/tests/run.py                  # tot
python3 plugin/tests/run.py --only ai,editor # doar unii pași (nume din --list; grupuri: static, suites)
python3 plugin/tests/run.py --list
python3 plugin/tests/run.py -v               # arată și ieșirea pașilor care trec
```

Doar Python 3 (biblioteca standard). La prima rulare `run.py` descarcă singur, în `plugin/tests/.cache/` (ignorat de git):

* ultima versiune Luau (`luau-ubuntu.zip` de pe github.com/luau-lang/luau; pe macOS / Windows asset-ul potrivit);
* `API-Dump.json` al Roblox (ramura `roblox` din MaximumADHD/Roblox-Client-Tracker), pentru verificarea de API.

Variabile de mediu: `LUAU_BIN_DIR` (director cu `luau`, `luau-analyze`, `luau-compile`, `luau-ast`; are prioritate, apoi
PATH, apoi `.cache`), `LUAU_VERSION=0.xxx` (fixează release-ul în loc de „latest”), `ROBLOX_API_DUMP=<fișier>` (dump local,
pentru rulare offline), `ROBLOX_API_REF=<ramură/commit>`. Cod de ieșire: 0 doar dacă toți pașii aleși trec. Dacă dump-ul nu
poate fi descărcat, `api-usage` apare ca „skip” (nu pică).

## Pașii

**Statici**

| Pas | Ce verifică |
|---|---|
| `compile` | `luau-compile` pe fiecare modul și pe fișierele de test: orice eroare de sintaxă oprește. |
| `analyze` | `luau-analyze` pe fiecare modul. Se ignoră doar zgomotul „Roblox”: globale (`game`, `Vector3`, …) și tipuri (`Instance`, …) necunoscute, plus „type inference failed” la fișierele mari. Orice altceva (variabilă nefolosită, global scris greșit, eroare de tip) pică. |
| `contracts` | Fiecare `Modul.membru` folosit în alt fișier (`UI.xxx`, `ctx.Editor.xxx`, `Analyzer.xxx`, `Tools.xxx`, culorile `C.xxx`, …) trebuie definit de modul. Prinde funcții redenumite / scrise greșit pe care Luau le-ar descoperi abia când se apasă butonul. |
| `api-usage` | Folosirea API-ului Roblox (clase, proprietăți, metode, enum-uri, tipuri literale, membri interziși pluginurilor) comparată cu `API-Dump.json`. Variabilele sunt urmărite linie cu linie, deci există fals-pozitive: cele analizate sunt în `data/api_usage_baseline.txt`, una nouă pică. API-urile depreciate apar doar ca notițe. |
| `multiret` | `find()` / `gsub()` ca ultim argument / element / valoare returnată (valorile în plus „curg” în parametrii următori). Constatările analizate: `data/multiret_baseline.txt`. |
| `patterns` | Fiecare pattern Lua literal din surse este rulat o dată: un pattern malformat altfel pică abia când se ajunge pe ramura lui. |
| `selftest` | Verificările de mai sus rulează pe fișiere cu defecte cunoscute (`data/samples/`): dacă una nu mai găsește nimic (un release Luau care schimbă JSON-ul `luau-ast`, o regulă stricată) nu devine un PASS tăcut. |
| `build` | `plugin/build.py` într-un fișier temporar; XML-ul se parsează, arborele de scripturi și `Source`-urile coincid cu folderul `LostCube/`. |
| `rbxmx-fresh` | `plugin/LostCube.rbxmx` din repo e identic cu ce produce `build.py` acum (altfel: `python3 plugin/build.py` și comite). |

Baseline-urile se rescriu cu `python3 plugin/tests/run.py --only api-usage,multiret --update-baselines` (uită-te la diff
înainte: fiecare linie e o constatare pe care ai judecat-o inofensivă).

**Suite Luau** (`suites/<nume>.test.luau`, câte un pas fiecare)

| Suită | Ce acoperă |
|---|---|
| `ai` | `AI.luau`: setări, corpul cererii și antetele, răspunsuri și erori HTTP (cu `HttpService` simulat), reîncercarea la 529, istoricul, fișa cu API-ul LostCube (module reale `AnimLibrary` / `AnimGen`, `Editor` simulat). |
| `ai_agent` | Modul agent: encoder-ul JSON, `rawField`, `truncate` și bucla `AI.runAgent` (tool_use / tool_result, corpuri de cerere „append-only”, limita de iterații, anulare, refuzuri, erori HTTP, reîncercări). Corpurile cererilor sunt re-validate în Python (`checks/validate_bodies.py`: JSON strict, schemele uneltelor, prefix identic între cereri ca să se refolosească cache-ul). |
| `tools` | `Tools.luau`: fiecare unealtă pe care o poate chema Claude (citire, scriere într-un singur pas Undo, rollback, `run_luau`, rezultate tăiate); uneltele de modelare 3D rulează pe motorul `Modeling` real (`bodies/tools_modeling.luau`, mock `modeling_env`). |
| `build_panel` | `BuildPanel` (tab-ul Modelare) + `UI` + `Modeling` reale pe mockul `modeling_env` și GUI-ul strict: formularul fiecărui generator, previzualizarea (amânată, în cameră, în afara Undo, dispare cu tab-ul / modul / panoul), Plasează / Actualizează într-un pas Undo, operațiile dezactivate cu motivul, toast cu „Anulează”, raportul de optimizare, `selfCheck` o singură dată. |
| `markdown` | `Markdown.luau`: `inline` (Markdown → RichText) și `parse` (blocuri, liste imbricate, tabele, cod, cazuri limită). |
| `claude_panel` | `ClaudePanel` + `UI` + `AI` + `Markdown` reale pe un GUI simulat strict (o proprietate greșită sau inexistentă dă eroare): cheie API, test de conexiune, chat, reîncercare, golire în timpul unei cereri. |
| `claude_panel_agent` | `ClaudePanel` în modul agent: conversație scriptată (citirile rulează singure, modificarea așteaptă un click pe card, „Permite mereu”, cod fără confirmare), oprire / golire cât așteaptă un card, erori și reîncercare, alt tab afișat, modul agent oprit = chatul simplu. Corpurile cererilor se validează ca la `ai_agent`. |
| `analyzer` | `Analyzer.luau` pe un joc simulat: pattern-uri de securitate / performanță, raport salvat și reîncărcat, context pentru Claude, scanare de free model, stocare pe bucăți, cache-ul raportului, numărătoarea de fundal pentru „analiza e veche”. |
| `analyzer_perf` | Același Analyzer pe ~100 000 de instanțe și 2 000 de scripturi: se termină, nu blochează un frame, contextul rămâne mic. |
| `analysis_panel` | `AnalysisPanel` + `UI` reale: prima analiză automată, secțiunile raportului, secțiuni pliate construite abia la deschidere, click pe o problemă deschide scriptul, filtre, „Analiză cu Claude” (pe o copie a raportului). |
| `ui` | `UI` + `Theme` + `Icons` reale pe GUI-ul simulat strict: API-ul 2.0 încă merge, fără emoji, tipografie, token-uri și re-skin live dintr-o temă Studio falsă, căile de iconițe verificate în manifestul Studio (`suites/data/studio_icons.luau`), fiecare componentă nouă (switch, scrub, slider, căutare, dropdown / meniu cu Esc și clic în afară, color picker, toast-uri, confirmare, tab-uri). |
| `app` | `App`: redesenări unite și amânate cât scrie utilizatorul, bara de tab-uri, o singură conexiune la Log, `destroy` deconectează tot. |
| `anim_panel` | `AnimPanel`: dummy din HumanoidDescription (numele `Async`, fără înregistrare Undo deschisă peste cererea web), redare, conexiunea Heartbeat, curățenie la `destroy`, textul markerului păstrat, lista sortată de clipuri. |
| `animgen` | `AnimGen`: matematică (matrice, axe, oglindire, IK) și verificare cinematică a fiecărei animații pe rig-uri R15 / R6 simulate; fără erori / NaN pe intrări ciudate. |
| `animgen_build` | `AnimGen.generate / save / measure` pe un mock de Instance / CFrame. |
| `anim_library` | `AnimLibrary`: datele și scriptul generat al fiecărui pachet, rulat pe un personaj simulat. |
| `library_panel` | `LibraryPanel` pe un API Roblox „proxy”: căutare, filtre, selecție, id propriu, linia de proprietar. |
| `library_panel_ui` | `LibraryPanel` pe mockul DataModel + GUI: dummy, verificarea proprietarului (`GetProductInfoAsync`), redare, căutarea păstrată la redesenare. |
| `editor` | `Editor` (motorul VFX) pe un mock tipizat după API-Dump: toate preseturile și șabloanele se construiesc, o singură înregistrare Undo, validări, recolorare / scalare, `importEmitters` / `importAsset` (scripturile modelului sunt șterse). |
| `vfx_panel` | `VFXPanel` cu un UI simulat: meniul de elemente, constructorul de șabloane, importul de VFX gratuite, selectorul de texturi. |
| `vfx_player` | `Editor/VFX.luau` se încarcă și expune API-ul. |
| `vfx_runtime` | Playerul VFX pe un mock tipizat cu ceas fals: planificatorul comun, planuri și pool-uri, calitate / viteză / distanță, sunete, beam-uri, cameră (shake / FOV / flash), pauză / stop, API-ul Editor pentru tipurile noi și panoul. |
| `installer` | `Installer`: stare, instalare, actualizare, fără duplicate, efectele păstrate, instalare eșuată anulată în Undo. |

## Cum funcționează testele Luau

`run.py` scrie, pentru fiecare suită, un fișier generat în `.cache/gen/` care conține **textul** tuturor surselor reale
(`LostCube/...`) și al fișierelor de test, apoi pornește `lib/boot.luau`. Sursele se execută cu `loadstring` + `setfenv`:
fiecare modul vede doar globalele (mockurile) pe care i le dă suita, iar erorile arată `LostCube/AI.luau:123`.

* `lib/kit.luau` – `check`, `eq`, `has`, `near`, `throws`, `section` (o secțiune care crapă nu oprește restul), `finish`.
* `lib/modtree.luau` – arborele de ModuleScript-uri (`script.Parent.UI`, `Editor/VFX`) și `require`; `mocks = { Modul = tabel }`
  înlocuiește un modul cu o variantă falsă, `LC.modtree.MISSING` îl face indisponibil.
* `mocks/` – Roblox simulat:
  `gui.luau` (instanțe GUI cu proprietăți permise explicit, semnale, planificator),
  `datamodel.luau` (joc cu servicii, copii, atribute, JSON ca `HttpService`; `enableGui()` pentru panouri) + `panel_prologue.luau`,
  `agent_env.luau` (JSON strict, ceas virtual, un singur Instance pentru GUI și DataModel, coadă de răspunsuri HTTP),
  `api_env.luau` și `vfx_env.luau` (instanțe și tipuri de date tipizate după `data/api_subset.json`, o parte din API-Dump;
  `vfx_env` adaugă ceas fals, tween-uri, cameră și sunete). Clase noi: adaugă-le în `checks/make_api_subset.py` (sau folosește-le în
  surse) și rulează `python3 plugin/tests/checks/make_api_subset.py` (are nevoie de `.cache/API-Dump.json`).
* `suites/bodies/` – corpul unor teste scrise să ruleze direct în mockul lor (folosesc globalele mockului: `check`, `has`, `load`, …);
  suita `.test.luau` le încarcă în mediul potrivit.

## Cum adaugi un test

1. **Un test într-o suită existentă**: adaugă `t.check(...)` / `t.eq(...)` în `suites/<nume>.test.luau`.
2. **O suită nouă**: creează `suites/<nume>.test.luau` (apare singură în `--list`). Șablon:

   ```lua
   local LC = ...
   local t = LC.kit.new("nume")
   local tree = LC.modtree.new{ env = LC.env{ game = ..., task = ... }, mocks = { Editor = LC.modtree.MISSING } }
   local Modul = tree.load("Modul")          -- sursa reală, din plugin/LostCube/Modul.luau
   t.eq("ce verific", Modul.f(1), 2)
   t.finish()                                -- scrie linia „LC-RESULT” și pică dacă ceva a eșuat
   ```
3. **Un mock nou**: un fișier în `mocks/` care întoarce un tabel; îl încarci cu `LC.run("tests/mocks/<nume>.luau", env, LC)`.
   Globalele pe care le definește ajung în `env` dacă îl rulezi cu `env = LC.env()` (vezi `mocks/gui.luau`).
4. Testează comportamentul public. Unde ai nevoie de o funcție internă, expune-o printr-un `patch` (vezi `suites/editor.test.luau`)
   și sari cu o notă dacă dispare, ca o refactorizare să nu strice testul.
5. Verifică că testul **pică** pe cod stricat (schimbă temporar sursa, în alt folder) înainte să te bazezi pe el.

## CI

`.github/workflows/lostcube.yml` rulează `python3 plugin/tests/run.py` pe `ubuntu-latest` la fiecare push / pull request care
atinge `plugin/**`. Rezultatul e același ca local. Release-ul Luau este „latest”: dacă un release nou strică ceva fără să se fi
schimbat codul, fixează `LUAU_VERSION` în workflow.

## Ce NU acoperă

Aspectul real al interfeței, redarea efectelor VFX cu rotații reale (CFrame complet, `Raycast`), animațiile pe un Animator real,
permisiunile și timpul maxim al `HttpService` din Studio, `init.server.luau` (toolbar / widget). Acestea se verifică în Studio.
Mockurile sunt aproximații: un test verde înseamnă că logica și contractele dintre module țin, nu că Studio se comportă identic.
