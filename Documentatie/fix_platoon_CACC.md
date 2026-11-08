# `fix_platoon_CACC.m`

[← Înapoi la prezentarea generală](../README.md)

## Rol

Script **de migrare, rulat o singură dată**, care a transformat modelul inițial `Platoon_Year1_CACC_modified.slx` în modelul corectat `Platoon_Year1_CACC_fixed.slx`. Aplică prin cod (API-ul Simulink: `add_block`, `add_line`, `set_param`) șase corecturi de control, fiecare justificată în literatura despre plutoane CACC.

Modelul `_fixed` rezultat este baza pe care lucrează apoi `add_cyber_to_platoon` și UI-ul.

## Starea actuală

Scriptul **nu mai trebuie rulat** și, în forma actuală a folderului, se oprește singur:

1. Dacă `Platoon_Year1_CACC_fixed.slx` există deja, se oprește cu eroare. Modelul conține între timp și partea cyber și logarea pentru UI, iar regenerarea le-ar pierde.
2. Dacă `Platoon_Year1_CACC_modified.slx` lipsește (cazul actual), se oprește cu eroare.

Rămâne în proiect ca **documentație executabilă** a modificărilor de control.

## Utilizare (istoric)

```matlab
init_platoon_params     % parametrii (h_CTH, D_DES, L_VEH, v0, t_step ...)
fix_platoon_CACC        % copiază modelul sursă în _fixed și aplică corecturile
```

## Problemele corectate

### P1 – Politica de spațiere greșită

**Înainte:** distanță țintă constantă, `D_Target = i·(D_DES + L_VEH)`, independentă de viteză.
**Problemă:** în topologia predecessor-following, politica de distanță constantă nu este string stable (Swaroop & Hedrick 1996; Rajamani; Naus 2010).
**După:** timp de gardă constant (CTH), `d_des = D_DES + L_VEH + h_CTH·v_ego`.

Implementare în fiecare `Follower_n/CACC_Controller`:

```
D_Target ("D_DES + L_VEH") ──┐
                             ├─▶ Sum_Dtarget ─▶ Sum_GapError/2
v_ego ─▶ Gain_h (h_CTH) ─────┘
```

### P2 – Inconsistență topologie / țintă

**Înainte:** comunicația era predecessor-following (fiecare urmăritor primește starea vehiculului din față), dar distanțele țintă erau raportate la lider (1×, 2×, 3×, 4×).
**După:** toate țintele sunt față de predecesor (factor 1×), consecvent cu topologia.

### P3 – Lipsea filtrarea feedforward-ului

**Înainte:** accelerația primită prin V2V era adunată direct în comanda de accelerație.
**După:** se trece prin filtrul `1/(h_CTH·s + 1)` (`FF_Filter`), conform Ploeg 2011 și Naus 2010, pentru a garanta `|Γ(jω)| ≤ 1`.

```
BusSel_Leader/3 (Accel) ─▶ FF_Filter [1]/[h_CTH 1] ─▶ Sum_CACC/1
```

> Mai târziu, `add_cyber_to_platoon` a inserat injectorul de atac între `BusSel_Leader` și `FF_Filter`.

### P4 – Scenariu nefizic pentru lider

**Înainte:** referința de viteză pornea de la 0, deși vehiculele plecau cu 20 m/s, ceea ce producea o frânare bruscă artificială la start. Derivata din regulatorul liderului era pură (amplifica zgomotul).
**După:**
- `Leader_Vehicle/Step`: `Before = v0`, `After = v_cmd_final`, `Time = t_step`.
- `Derivative_Leader` este înlocuit cu derivata filtrată `s/(0.05·s + 1)`.

### P5 – Pierderi de pachete perfect corelate

**Înainte:** toate cele 4 legături V2V foloseau aceeași sămânță (`Seed = 42`), deci pierderile se produceau simultan pe toate legăturile, ceea ce e nerealist.
**După:** semințe distincte, `42, 137, 251, 389`, pe `V2V_Network`, `V2V_Network1`, `V2V_Network2`, `V2V_Network3`.

### P6 – Condiții inițiale neconsistente

**Înainte:** distanțele inițiale (~14.5 m) nu corespundeau echilibrului CTH la viteza de start, ceea ce producea un tranzitoriu mare.
**După:** integratoarele pornesc la echilibru:
- `Int_v2x` (poziție): `x0_leader = 130`, respectiv `x0_f(n) = 130 − n·gap0`
- `Int_a2v` (viteză): `v0`

## Setările solverului

```matlab
set_param(dstModel, 'Solver','ode23tb', 'MaxStep','0.01', 'RelTol','1e-4', ...
          'StopTime', num2str(t_step + 50));
```

- `MaxStep = 0.01 s` urmărește rata comunicației (100 Hz).
- `StopTime = t_step + 50` acoperă manevra liderului și regimul tranzitoriu. Varianta veche (40 s fix) nu prindea manevra la `t_step = 50`.
- UI-ul suprascrie oricum `StopTime` cu `inf`.

## Detalii de implementare

- Lucrează pe o **copie**: încarcă sursa, o salvează ca `_fixed`, închide sursa fără modificări, apoi editează doar copia.
- Pozițiile inițiale sunt scrise **numeric** (`num2str`), deci nu urmăresc automat modificările ulterioare din `init_platoon_params`.
- Înlocuirea derivatei liderului și setarea semințelor sunt în `try/catch`; dacă blocurile nu se găsesc, apare un avertisment și scriptul continuă.
- La final salvează și deschide modelul și afișează ce trebuie verificat (amplitudinea perturbației trebuie să scadă de la F1 spre F4).
