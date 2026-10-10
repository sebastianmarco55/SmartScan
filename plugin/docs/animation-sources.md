# Animații gratuite ale Roblox: surse, verificare, limite

Document pentru `plugin/LostCube/AnimLibrary.luau` (datele) și `plugin/LostCube/LibraryPanel.luau` (tab-ul „📚 Bibliotecă”).
Colectat la 10.10.2026.

## 1. De ce doar animații deținute de Roblox

Un asset de animație (`rbxassetid://ID`) se poate reda într-un joc doar dacă este deținut de creatorul jocului (utilizator
sau grup) **sau de Roblox**. Prin urmare singurele animații gratuite care merg garantat în *orice* joc, fără să le urci tu,
sunt cele create de Roblox:

- animațiile implicite ale personajelor (scriptul `Animate`, R15 și R6);
- pachetele de animații din catalog făcute de Roblox (Ninja, Mage, Zombie, ...);
- emote-urile din scriptul `Animate` (wave, point, cheer, laugh, dans 1/2/3).

Un ID găsit pe un site sau într-un script comunitar poate apărea ca „animație Roblox” și totuși să fie al altcuiva: de aceea
în date intră doar ID-uri confirmate de cel puțin două surse independente, iar tab-ul are butonul **„Verifică proprietarul”**
care întreabă Roblox live (vezi secțiunea 5).

## 2. Rezumat

| | număr |
|---|---|
| grupuri de animații de tip pachet (`PACKS`) | 21 |
| – pachete din catalog (Creator Docs) | 17 |
| – seturi implicite / clasice | 4 (Implicit R15, Implicit R6, Clasic pe R15, R15 vechi) |
| grupuri de emote (`EMOTE_GROUPS`) | 3 (R15, R6, clasice pe R15) |
| animații în pachete | 219 |
| emote-uri (`EMOTES`) | 39 |
| intrări în `AnimLibrary.all()` | 258 (247 ID-uri distincte) |
| marcate `verified = "api"` | 0 (API-urile Roblox nu au fost accesibile, vezi secțiunea 3) |
| marcate `verified = "2-sources"` | 258 |

Pachetele din catalog (toate R15): Astronaut, Bubbly, Cartoony, Elder, Knight, Levitation, Mage, Ninja, Pirate, Robot,
Rthro, Stylish, Superhero, Toy, Vampire, Werewolf, Zombie. Starea fiecăruia: idle (3 variante), walk, run, jump, fall,
climb, swim, swimidle. Seturile implicite/clasice mai au și sit, toolnone, toolslash, toollunge acolo unde sursele le dau.

## 3. Cum s-a verificat

### Proprietarul prin API: nu s-a putut
Ținta era `https://economy.roblox.com/v2/assets/<id>/details` (`Creator.Name == "Roblox"`, `AssetTypeId == 24`).
Din mediul în care s-au colectat datele toate gazdele Roblox (`economy.`, `apis.`, `develop.`, `catalog.`,
`assetdelivery.roblox.com`, `create.roblox.com`, `devforum.roblox.com`, `roblox.fandom.com`) sunt blocate de politica de
ieșire (CONNECT răspunde 403), iar `WebFetch` nu rezolvă DNS pentru ele. De aceea **nicio intrare nu are `verified = "api"`**.

### Regula înlocuitoare: două surse independente
Un ID intră în date doar dacă apare, **la aceeași stare și același pachet**, în cel puțin două surse care nu sunt copii
una după alta (documentația Roblox, scripturi din clientul Roblox, copii ale scriptului `Animate` din Studio, extensia
BTRoblox, liste comunitare). Pașii:

1. Tabelul pachetelor din Creator Docs a fost parsat automat și comparat cu trei transcrieri comunitare independente
   (stare cu stare, pentru toate cele 17 pachete). 16 din 17 coincid perfect; diferența (Astronaut walk) e explicată în 4.
2. Valorile implicite R15/R6, clasicul și emote-urile vin din scripturile `Animate` ale Roblox și sunt confirmate de copii
   separate (secțiunea 4).
3. Apoi un script a numărat, pentru **fiecare dintre cele 258 de ID-uri din date**, în câte familii de surse apare. Rezultat:
   minimum 2 familii pentru toate (68 de intrări în exact 2 familii, restul în 3–7). Familiile sunt: Creator Docs, 3 liste
   comunitare, scripturile Animate din Roblox-Client-Tracker, copia RCC 2021, EgoMoose, Roblox/gear, OpenSB (rbxmx din Studio),
   BTRoblox, `humanoidClassicAnimate`, `standardAnimationIds` (Avatar Settings), R15 Migrator.
4. Scriptul generat pentru „animații implicite” a fost compilat și analizat cu `luau-compile`/`luau-analyze` pentru toate cele
   21 de pachete și rulat într-un mediu simulat (greutăți idle, ștergerea idle-urilor în plus, idempotență între
   `CharacterAdded` și `CharacterAppearanceLoaded`, rig nepotrivit lăsat neatins).

Limita rămasă: „două surse” confirmă că ID-ul e *atribuit* acelei animații în catalogul Roblox, nu *dovedește* proprietarul.
Pentru pachetele din catalog și scripturile Animate proprietarul Roblox e practic sigur (documentația Roblox recomandă exact
aceste ID-uri pentru orice joc), dar nu l-am putut confirma prin API. Verificarea live se face din tab (secțiunea 5).

## 4. Surse

### Documentație și cod Roblox
- Creator Docs, „Use animations”: tabelul „Catalog animations” (17 pachete cu ID-uri), numele copiilor din `Animate`
  și exemplul cu `CharacterAppearanceLoaded`.
  https://create.roblox.com/docs/animation/using ·
  https://github.com/Roblox/creator-docs/blob/main/content/en-us/animation/using.md
- Creator Docs, „Emotes” (ID-uri de emote din catalog, nevrificate, secțiunea 6):
  https://github.com/Roblox/creator-docs/blob/main/content/en-us/characters/emotes.md
- Roblox-Client-Tracker (oglindă a fișierelor din clientul Roblox), ramura `roblox`:
  - `avatar/scripts/humanoidAnimateR15.lua`: scriptul Animate R15 curent (tabelul `animNames`, ID-urile „vechi”);
  - `avatar/scripts/humanoidAnimateSAuth/humanoidAnimateSAuth.lua`: conține și tabelul R6 și pe cel R15;
  - `avatar/scripts/humanoidAnimatePlayEmote/init.client.lua`: ID-urile R6 și emote-urile;
  - `avatar/unification/humanoidClassicAnimate.lua`: Animate „clasic” (animații în stil R6 pe rig R15);
  - `BuiltInPlugins/R15Migrator/Src/Util/AnimationConversion/robloxAnimationsMap.luac.s`: harta R6 → R15 din pluginul
    Roblox R15 Migrator (confirmă perechile clasice și ID-urile R6);
  - `BuiltInStandalonePlugins/AvatarSettings/Src/Util/AvatarPreview/standardAnimationIds.luac.s`: pluginul Avatar Settings,
    „StandardR15” / „StandardR6”.
  https://github.com/MaximumADHD/Roblox-Client-Tracker
- Roblox/gear, scriptul `Animate` (R6): `src/gear/32355759/src/Animate/init.server.luau`
  https://github.com/Roblox/gear

### Copii ale scriptului Animate / date independente
- OpenSB, `assets/server/R15Animate.rbxmx` și `R6Animate.rbxmx`: copii ale scriptului Animate implicit, cu ierarhia completă
  de copii (`StringValue` cu `Animation` și `Weight`); de aici vin ID-urile **implicite R15** (walk 913402848, run 913376220,
  swim 913384386, swimidle 913389285), confirmate de BTRoblox și de Avatar Settings, și numele copiilor. https://github.com/Open-SB/OpenSB
- BTRoblox (extensia de browser), `js/pages/common.js`: lista animațiilor implicite pe care o folosește previzualizatorul
  de avatar (R15 și R6). https://github.com/AntiBoomz/BTRoblox
- EgoMoose/character-animate: `src/AnimateR15.lua`, `src/AnimateR6.lua`. https://github.com/EgoMoose/character-animate
- polybotofc/vedora, `humanoidR15Animate.lua`: copie a scriptului Animate din clientul Roblox 2021 (ID-urile „vechi” R15).

### Liste comunitare (doar transcrieri de cross-check, nu autoritate)
Trei liste din scripturi comunitare de schimbat animații, care se contrazic uneori; au fost folosite numai ca transcrieri
independente ale ID-urilor din catalog:
- `Yasser-Arras/Scripts`, `Tools/AnimationsHub.lua` (cea mai completă: toate stările, idle 1-3, plus pachete în plus)
- `VeztWare/Vezt`, `Vezt-Animations.lua`
- `bonaganbj5-boop/animationpack`, o listă „Animation Changer”

### Căutări web (doar rezumate; paginile Roblox sunt blocate din mediul de colectare)
- Roblox Fandom, „Canceled items / Animation packs”: https://roblox.fandom.com/wiki/Canceled_items/Animation_packs
- DevForum, „Roblox Animation Pack IDs (Walk, Run, Jump etc.)”: https://devforum.roblox.com/t/roblox-animation-pack-ids-walk-run-jump-etc/417725
- DevForum, „How to change players animation pack?” (ID-urile Oldschool diferă): https://devforum.roblox.com/t/how-to-change-players-animation-pack/2271515

### Discrepanțe găsite și cum au fost rezolvate
| Subiect | Ce s-a găsit | Decizie |
|---|---|---|
| Astronaut walk | Creator Docs dă 891636393 (identic cu run); 3 liste comunitare dau 891667138 | 891667138 (probabil greșeală în documentație) |
| Rthro idle | Docs: 2510197257, 2510196951; toate listele comunitare au 2510196951 primul | 2510196951 = idle principal |
| „Implicit R15” | Scriptul din client are ca rezervă walk 507777826, run 507767714, swim 507784897; copia OpenSB a lui Animate, BTRoblox și Avatar Settings (plugin Studio) folosesc 913402848 / 913376220 / 913384386 | „Implicit R15 (Studio)” = acestea; cele vechi = „R15 vechi (original)” |
| R15 idle | Animate implicit (OpenSB, BTRoblox): 507766388 (greutate 9) + 507766666 (greutate 1); scriptul din client mai are și 507766951 | Implicit: 2 idle; „R15 vechi”: 3 |
| Clasic, climb | Animate clasic și R15 Migrator: 12520982150; Avatar Settings: 120984708189086 | 12520982150 (2 fișiere Roblox); celălalt în secțiunea 6 |
| R6 walk/run | Același ID (180426354) în toate sursele | `walk` și `run` identice |

### Ierarhia scriptului Animate (verificată în copiile rbxmx și în Creator Docs)
`character.Animate` conține câte un `StringValue` pe stare, cu `Animation` în el (idle are și un `Weight` NumberValue pe fiecare):

| stare | dosar | copii `Animation` |
|---|---|---|
| idle | `idle` | `Animation1`, `Animation2` (`Animation3` doar în unele variante); `Weight` 9 / 1 |
| walk | `walk` | `WalkAnim` |
| run | `run` | `RunAnim` |
| jump | `jump` | `JumpAnim` |
| fall | `fall` | `FallAnim` |
| climb | `climb` | `ClimbAnim` |
| swim (doar R15) | `swim` | `Swim` |
| swimidle (doar R15) | `swimidle` | `SwimIdle` |
| sit | `sit` | `SitAnim` |
| unelte | `toolnone` / `toolslash` / `toollunge` | `ToolNoneAnim` / `ToolSlashAnim` / `ToolLungeAnim` |

Abordarea din Creator Docs (un `Script` în ServerScriptService care schimbă `AnimationId` după ce personajul a apărut) este cea
generată de buton. Scriptul rezultat (`LostCubeAnimationPack`) rulează pe `CharacterAdded` și `CharacterAppearanceLoaded`,
așteaptă `Animate`, aplică pachetul doar dacă tipul rig-ului (R15/R6) se potrivește, oprește piesele în redare (ca în
documentație), setează `Weight` 9/1/1 la idle și șterge idle-urile care nu sunt în pachet.

## 5. Verificarea proprietarului din plugin

În tab: **„Verifică proprietarul”** (o animație) și **„Verifică tot grupul”** (un pachet) apelează
`MarketplaceService:GetProductInfo(id, Enum.InfoType.Asset)` și arată creatorul și tipul asset-ului:
- `✓` creator Roblox și tip 24 (Animation): merge în orice joc;
- `⚠` tip 61 (Emote din catalog): nu e o animație redabilă direct;
- `✗` alt creator: merge în joc doar dacă e al creatorului jocului.

Secțiunea „ID personalizat” (pliată) permite să testezi orice ID (inclusiv cele din secțiunea 6) înainte să-l folosești.
Echivalent din linia de comandă, de pe o mașină cu acces la Roblox:
`curl https://economy.roblox.com/v2/assets/<id>/details` (în răspuns: `Creator.Name` și `AssetTypeId`).

## 6. Nevrificat (nu e în date)

Nimic din această secțiune nu este în `AnimLibrary`. Motiv: o singură familie de surse (liste comunitare care se copiază
între ele) sau ID-uri contestate.

### Pachete găsite doar în liste comunitare
Oldschool: ID-urile din listă (5319828216 etc.) **nu coincid** cu cele dintr-un thread DevForum (alt set: 5319900634 pentru
run/walk, 5319917561 jump, 5319914476 fall), deci nu se știe care e corect. Princess, Confident, Cowboy: Roblox Fandom le listează
la „Canceled items”, iar o căutare web confirmă idle/walk/run egale cu lista comunitară, restul stărilor nu. Popstar și Patrol au
același Idle 2 (1150842221), probabil o copiere greșită; într-una din liste Patrol jump = Patrol climb (greșeală evidentă). Pachetele
cu ID-uri de 14–15 cifre (Wicked, Catwalk, Amazon, NFL, Adidas Community/Aura) sunt recente și pot aparține partenerilor, nu Roblox.

Ca să le testezi: lipește un ID în „ID personalizat”, apasă „Verifică proprietarul”, apoi redă.

| Pachet | Idle | Idle 2 | Idle 3 | Walk | Run | Jump | Climb | Fall | Swim | SwimIdle |
|---|---|---|---|---|---|---|---|---|---|---|
| Oldschool | 5319828216 | 5319831086 | 5392107832 | 5319847204 | 5319844329 | 5319841935 | 5319816685 | 5319839762 | 5319850266 | 5319852613 |
| Princess | 941003647 | 941013098 | 1159195712 | 941028902 | 941015281 | 941008832 | 940996062 | 941000007 | 941018893 | 941025398 |
| Confident | 1069977950 | 1069987858 | 1116160740 | 1070017263 | 1070001516 | 1069984524 | 1069946257 | 1069973677 | 1070009914 | 1070012133 |
| Popstar | 1212900985 | 1150842221 | 1239733474 | 1212980338 | 1212980348 | 1212954642 | 1213044953 | 1212900995 | 1212852603 | 1212998578 |
| Patrol | 1149612882 | 1150842221 | 1159573567 | 1151231493 | 1150967949 | 1150944216 | 1148811837 | 1148863382 | 1151204998 | 1151221899 |
| Sneaky | 1132473842 | 1132477671 | - | 1132510133 | 1132494274 | 1132489853 | 1132461372 | 1132469004 | 1132500520 | 1132506407 |
| Cowboy | 1014390418 | 1014398616 | 1159487651 | 1014421541 | 1014401683 | 1014394726 | 1014380606 | 1014384571 | 1014406523 | 1014411816 |
| Bold | 16738333868 | 16738334710 | 16738335517 | 16738340646 | 16738337225 | 16738336650 | 16738332169 | 16738333171 | 16738339158 | 16738339817 |
| AdidasSports | 18537376492 | 18537371272 | 18537374150 | 18537392113 | 18537384940 | 18537380791 | 18537363391 | 18537367238 | 18537389531 | 18537387180 |
| AdidasCommunity | 122257458498464 | 102357151005774 | - | 122150855457006 | 82598234841035 | 75290611992385 | 88763136693023 | 98600215928904 | 133308483266208 | 109346520324160 |
| AdidasAura | 110211186840347 | 114191137265065 | - | 83842218823011 | 118320322718866 | 109996626521204 | 97824616490448 | 95603166884636 | 134530128383903 | 94922130551805 |
| WickedDancing | 92849173543269 | 132238900951109 | - | 73718308412641 | 135515454877967 | 78508480717326 | 129447497744818 | 78147885297412 | 110657013921774 | 129183123083281 |
| WickedPopular | 118832222982049 | 76049494037641 | - | 92072849924640 | 72301599441680 | 104325245285198 | 131326830509784 | 121152442762481 | 99384245425157 | 113199415118199 |
| Catwalk | 133806214992291 | 94970088341563 | - | 109168724482748 | 81024476153754 | 116936326516985 | 119377220967554 | 92294537340807 | 134591743181628 | 98854111361360 |
| Amazon | 98281136301627 | 138183121662404 | - | 90478085024465 | 134824450619865 | 121454505477205 | 121145883950231 | 94788218468396 | 105962919001086 | 129126268464847 |
| NFL | 92080889861410 | 74451233229259 | - | 110358958299415 | 117333533048078 | 119846112151352 | 134630013742019 | 129773241321032 | 132697394189921 | 79090109939093 |
| NoBoundaries | 18747067405 | 18747063918 | - | 18747074203 | 18747070484 | 18747069148 | 18747060903 | 18747062535 | 18747073181 | 18747071682 |

### Alte ID-uri nevrificate
- **Emote din catalog** (Creator Docs, „Emotes”): Hello 3576686446, Stadium 3360686498, Tilt 3360692915, Shrug 3576968026,
  Salute 3360689775, Point 3576823880; o căutare web mai dă Applaud 5915779043. Sunt ID-urile folosite cu
  `HumanoidDescription:SetEmotes` / `Humanoid:PlayEmote`. Un emote din catalog (tip 61) înfășoară o `Animation` cu alt ID, deci
  s-ar putea să nu meargă direct ca `AnimationId`. ID-urile vechi Shrug 3333499508 și Hello 3344650532 (dintr-un plugin comunitar)
  nu apar în nicio sursă oficială, probabil depășite.
- **Clasic pe R15**: climb alternativ 120984708189086 și swim 12518152696 (doar în Avatar Settings, o singură sursă).
- **R15 Migrator**: harta R6 → R15 mai are perechi cu nume necunoscut (de ex. 125750544 → 13842624027, 125750618 → 13842624352,
  125749145 → 13842624225, 125750759 → 13842624498, 125750800 → 13842624634, 125750867 → 13842624036, 45828430 → 13978512316,
  45873069 → 13978507503, 85576403 → 13978510688, 85723345 → 13978511071, 32659699 → 13978511543, 32659703 → 13978511983,
  32659706 → 13978504790). Nu se știe ce animație e fiecare.
- Animația de „mood” din Animate (7715096377): animație de față, nu de corp.
- Pachete R6: nu există pachete R6 de catalog în sursele găsite; singurul set R6 verificat este cel implicit.

## 7. Licență și utilizare

- Un asset deținut de Roblox poate fi **redat** în orice experiență Roblox, gratuit și fără permisiuni suplimentare. Nu poți
  descărca fișierul animației din Studio, iar utilizarea rămâne supusă Termenilor Roblox.
- Pachetele de catalog scoase de la vânzare rămân ale Roblox și continuă să meargă; Roblox poate însă oricând să retragă un asset,
  de aceea există verificarea live.
- Referința în joc este doar `rbxassetid://ID`; nu se copiază nimic din animație în proiectul tău.
- Animațiile personalizate (atacuri etc.) se fac în tab-ul „Animații”; acelea trebuie încărcate în contul/grupul jocului.

## 8. Reproducere

1. Descarcă fișierele din secțiunea 4 de pe `raw.githubusercontent.com` (accesibil din mediu).
2. Parsează tabelul „Catalog animations” din `using.md` și compară stare cu stare cu lista comunitară și cu alte două.
3. Pentru fiecare ID din `AnimLibrary.all()` numără familiile de surse în care apare (≥ 2).
4. Rulează scriptul generat prin `AnimLibrary.packScript(pack)` prin `luau-compile` și `luau-analyze`.
