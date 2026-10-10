# LostCube – plugin Roblox Studio (VFX + animații)

Editor de efecte VFX cu previzualizare live, previzualizare de animații cu easing în stil Moon,
și aceleași unelte pentru Claude (`ReplicatedStorage.LostCube.Editor`).

## Instalare
1. `python3 plugin/build.py` (sau folosește `plugin/LostCube.rbxmx` deja generat)
2. În Studio: **Plugins → Plugins Folder**, copiază `LostCube.rbxmx` acolo, repornește Studio.
3. Butonul **LostCube** din toolbar deschide panoul. În tab-ul *Claude* instalezi modulele în joc.

## Structură
- `LostCube/` – sursele Luau (`init.server.luau` = Script, restul ModuleScript-uri)
  - `Editor/` – crearea/editarea efectelor (folosit de panouri și de Claude); `Editor/VFX.luau` – player-ul din joc
  - `VFXPanel`, `AnimPanel`, `ClaudePanel`, `App`, `UI`, `Installer` – interfața
- `build.py` – împachetează sursele în `LostCube.rbxmx`

## Cum se folosește (noutăți)
- **Ctrl + rotiță** pe un câmp numeric schimbă valoarea (Shift = ×10). Rotița simplă doar derulează panoul.
- Ține mouse-ul pe un buton sau câmp ca să vezi indiciul (ex. „timp (s) · luminozitate · rază” la chei).
- **⏹** lângă Redă/Pauză scoate previzualizarea din scenă și oprește bucla.
- Scurtături: *File → Advanced → Customize Shortcuts*, caută „LostCube” (redă efectul / oprește previzualizarea).
- În joc, `VFX.play("Nume", personaj)` găsește singur efectele din `ReplicatedStorage.LostCube.Effects`
  (nu mai e nevoie de `VFX.Library = ...`).
- Pluginul ține minte tab-ul deschis și secțiunile pliate între sesiuni.

## Modificări față de versiunea primită (1.5.0 → 1.6.0)
Versiunea modulelor a crescut la 1.6.0: panoul arată „Instalează / actualizează modulele” în jocurile care au 1.5.0.
Apasă butonul ca să ajungă reparațiile din player și în joc.

**Player-ul din joc (`VFX`)**
- elementele Mesh 3D erau scalate de două ori (`scale = 2` dădea piese de 4× mai mari)
- la viteză > 1 efectul era șters înainte ca piesele 3D să dispară (se tăia brusc); la viteză < 1 rămânea prea mult
- Trail-urile respectă acum viteza de redare, ca particulele (slow-motion le estompează încet)
- luminile fără chei nu se măreau cu `scale`
- piesele 3D dintr-o previzualizare pusă pe pauză nu mai rămân în scenă după reluare
- dacă personajul pe care e prins efectul dispare, efectul rămâne pe loc în loc să cadă
- `VFX.play("Nume")` caută implicit în `ReplicatedStorage.LostCube.Effects`

**Editor și panouri**
- secțiunile se pliază/desfac efectiv și starea se păstrează
- indiciile (`tip`) existau în cod, dar nu se afișau niciodată; acum apar la hover
- rotița pe câmpurile numerice modifica valori când doar derulai panoul; acum cere Ctrl și face un singur pas de Ctrl+Z
- previzualizare: buton ⏹; o previzualizare pe pauză nu mai rămâne înghețată; „Repetă” respectă Pauza
- previzualizarea nu mai sare la origine când e selectat un element al efectului (din „Selectează în Explorer”)
- markere cu spațiu sau cratimă în nume (ex. „Hit 1”) nu puteau primi efect (eșua în tăcere); acum merg, iar erorile se văd
- tab-ul Animații: după Stop / easing / marker butonul nu mai rămâne pe „Pauză”; ◀ ▶ fără rig spun de ce nu merg
- instalarea modulelor se anulează curat dacă eșuează
- duplicarea unui element păstrează tot (mute, urme pe sol, lift/flow, opțiuni Trail); duplicarea unui efect dă nume unice
- crearea/redenumirea cu nume gol sau existent e refuzată cu mesaj; `Editor.retime` refuză factori ≤ 0
- mesajele de eroare apar curate (fără calea modulului) și o singură dată
