# Previzualizare GUI (fără Roblox Studio)

`render.py` desenează **interfața reală** a pluginului (`App` + panourile din `plugin/LostCube/`) în PNG. Codul Luau rulează în CLI-ul
Luau pe obiecte GUI simulate (cu un joc demo: efecte VFX, raport de analiză, animații, cheie API, chat), arborele GUI rezultat
e convertit în HTML care reproduce regulile de layout Roblox, iar Chromium (Playwright) îl pune în pagină, îl măsoară și face poza.

## Rulare

```
python3 plugin/tests/preview/render.py --tab VFX                  # Anim | Library | Game | Build | Claude  →  preview/out/VFX-dark.png
python3 plugin/tests/preview/render.py --tab Game --theme light --width 420 --height 1200
python3 plugin/tests/preview/render.py --all                      # toate tab-urile, ambele teme → preview/out/<Tab>-<temă>.png
python3 plugin/tests/preview/render.py --tab Claude --full        # înălțime cât tot conținutul (nu doar 900 px)
python3 plugin/tests/preview/render.py --tab Anim --open anim.gen --close anim.rig --click "Lovitură" --hover "Previzualizează"
python3 plugin/tests/preview/render.py --tab VFX --state empty --out /tmp/gol.png
```

Opțiuni: `--theme dark|light` (tema Studio simulată), `--width/--height` (implicit 360×900), `--scale` (implicit 2),
`--open KEY` / `--close KEY` (secțiuni pliabile; cheile apar cu `-v`: „sections: …”), `--click TEXT` (apasă butonul care arată
textul respectiv, după ce tab-ul e afișat: deschide meniuri / popup-uri, alege un efect, un element, o animație),
`--hover TEXT` (culoare de hover, tooltip), `--state demo|empty`, `--font-scale N`, `--offline`, `-v`
(note, erori Luau cu traseu, conținut Roblox negăsit, cheile secțiunilor). Pagina HTML rămâne lângă PNG (`out/*.html`,
se poate deschide în browser și inspecta). `--tab Selftest` desenează un ecran de verificare a renderer-ului (fără plugin).

Cerințe: Python 3, `pip install playwright` (doar biblioteca; browserul nu se descarcă: se folosește un Chromium existent din
`$PLAYWRIGHT_BROWSERS_PATH`, `/opt/pw-browsers` sau `$PLAYWRIGHT_CHROMIUM=/cale/chrome`), `git` și acces la GitHub (Luau CLI,
fonturi și imagini se descarcă o dată în `plugin/tests/.cache/`; `--offline` le sare). Fontul pentru emoji (Noto Color Emoji)
trebuie să fie instalat în sistem, altfel Chromium arată pătrățele.

## Cum funcționează

| Fișier | Rol |
|---|---|
| `main.luau`, `common.luau`, `scenes/*.luau` | scena fiecărui tab: lume simulată + `App` real montat, apoi tab / secțiuni / clicuri; scrie arborele GUI ca JSON |
| `gui.luau` | mock GUI îngăduitor (orice proprietate se reține), tipuri de date Roblox (userdata), `Enum`, `Font`, planificator virtual (`task.*`), `TweenService` (aplică ținta direct), `settings().Studio.Theme` (culori Dark / Light aproximative pentru fiecare `StudioStyleGuideColor`), `StudioService:GetClassIcon`, servicii necunoscute = stub |
| `htmlgen.py`, `page.css`, `page.js` | JSON → HTML (UDim2 → `calc()`, AnchorPoint, UIListLayout → flexbox, UIGridLayout, UIPadding, AutomaticSize, UICorner / UIStroke / UIGradient, ClipsDescendants, ScrollingFrame cu bară, ZIndex, RichText, ImageLabel cu decupare de sprite…) |
| `assets.py` | fonturi, imagini `rbxasset://` din mirror-ul `MaximumADHD/Roblox-Client-Tracker` (descărcate fișier cu fișier), pictogramele de clase (`ClassImages.PNG` + `ReflectionMetadata.xml`) |
| `render.py` | orchestrare: Luau → HTML → Chromium → măsurători → PNG |

**Măsurători în buclă:** codul real citește `AbsoluteSize`, `AbsolutePosition`, `AbsoluteContentSize`, `AbsoluteCanvasSize`,
`TextBounds` (ex. `UI.scrollList` își ia înălțimea din conținut, popup-urile se așază după butonul care le deschide, chatul
sare la ultimul mesaj). Chromium măsoară fiecare element, iar trecerea următoare a scenei primește numerele; se repetă până se
stabilizează (de obicei 3 treceri).

## Fidel și aproximativ

Fidel (după regulile Roblox): dimensiuni și poziții (scale + offset, AnchorPoint), ordinea după `LayoutOrder`, `Padding`,
aliniere, `HorizontalFlex = Fill` / `SpaceBetween…`, `UIFlexItem`, `Wraps`, `UIPadding`, `AutomaticSize` (Size = minim),
`ClipsDescendants`, `ZIndex` (Sibling), `Visible`, trunchiere cu `…`, text împărțit pe rânduri, RichText (`b i u s font uc sc stroke mark br`),
culori, colțuri rotunjite, contur `UIStroke` în afara elementului (ca Roblox), gradient, sprite-uri, bara de scroll,
tema Studio citită prin `settings().Studio.Theme`.

Aproximativ:

* **Fontul.** Builder Sans nu e disponibil public (nici în mirror), deci se folosește **Inter**. Lățimile diferă puțin: o
  etichetă la limită se poate trunchia diferit în Studio. Dacă ai Builder Sans (din instalarea Roblox, `content/fonts/`), pune
  `BuilderSans-Regular.otf`, `-Medium`, `-Bold`, `-ExtraBold` în `plugin/tests/preview/fonts/` (ignorat de git) și se folosesc ei.
* **Mărimea textului.** Se presupune că o linie Roblox are înălțimea `TextSize` și că „em”-ul fontului e `TextSize / 1.26`
  (înălțimea naturală a lui Builder Sans, ca în `FontScales` din Foundation). Dacă în Studio textul ți se pare mai mare / mai mic:
  `--font-scale 1` (em = TextSize) sau altă valoare.
* **Culorile temei Studio** (`GetColor`) sunt aproximative (Roblox nu publică tabelul); stările Hover / Pressed / Selected sunt
  derivate. Culorile din Studio-ul tău pot diferi puțin.
* `HorizontalFlex` / `VerticalFlex = Fill` se redă ca `flex: 1 1 auto` din CSS (spațiul liber se împarte egal, iar la lipsă de loc
  elementele se micșorează proporțional cu mărimea lor); Roblox poate distribui puțin altfel când elementele au mărimi diferite.
* Regulile fuzzy sunt simplificate: scara din `UIPadding` pe sus / jos, `UICorner` care taie copiii, rotația, `UIPageLayout` /
  `UITableLayout` (tratate ca listă), `TextScaled` (potrivit prin încercări), `ViewportFrame` / `VideoFrame` (goale), scroll orizontal.
* **Imagini:** `rbxasset://` se descarcă din mirror când fișierul există acolo; `rbxassetid://` (încărcate pe Roblox) și ce lipsește
  din mirror sunt dreptunghiuri hașurate cu numele / id-ul. Imaginile cu `ImageColor3` ≠ alb sunt colorate ca o mască (merge pentru
  pictograme albe, nu pentru imagini colorate).
* **Date:** jocul, efectele și animațiile sunt simulate (Editor-ul real rulează pe mockul tipizat al testelor; în celelalte
  tab-uri Editor-ul e un substitut mic, iar Claude / HTTP nu sunt chemate: conversația e pusă direct în panou, analiza lui
  Claude din tab-ul Joc e un răspuns fix). Nu se văd animații, hover / focus / cursor (doar prin `--hover`), nici redarea efectelor.
* Metodele sau membrii GUI necunoscuți nu opresc nimic: citirea lor dă `nil` (apare ca „note” cu `-v`); un serviciu necunoscut devine un stub.

## Cum se schimbă

* Alt joc demo / alt conținut: `scenes/vfx.luau` (efecte), `scenes/build.luau` (Modelare: motorul real pe mockul `modeling_env`; variante cu `--open build.demo.parts` / `build.demo.model`), `scenes/game.luau` (lumea comună: părți, scripturi cu probleme, remote-uri),
  `scenes/anim.luau`, `scenes/library.luau`, `scenes/claude.luau` (cheia API și conversația).
* O clasă GUI nouă folosită de plugin: se redă după nume dacă `htmlgen.py` o cunoaște (`GUI_OBJECTS`); proprietățile noi se păstrează în dump
  (`gui.luau` nu are listă de proprietăți permise), dar trebuie citite în `htmlgen.py` ca să se vadă.
* Ieșirea (`out/`) și fonturile proprii (`fonts/`) sunt în `.gitignore`.
