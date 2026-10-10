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

## Modificări față de versiunea primită
- secțiunile din panou se pliază/desfac acum efectiv (înainte click-ul pe antet nu făcea nimic vizibil)
- tab-ul Animații: după Stop / aplicare easing / marker butonul nu mai rămâne pe „Pauză”
- instalarea modulelor se anulează curat dacă eșuează (nu mai rămâne o înregistrare Ctrl+Z deschisă)
- duplicarea unui element păstrează tot (mute, urme pe sol, lift/flow, opțiuni Trail)
- duplicarea unui efect de mai multe ori dă nume unice; redenumirea/crearea cu nume gol sau existent e refuzată
- `Editor.retime` refuză factori ≤ 0
- erorile din panoul VFX apar o singură dată, nu rămân lipite
