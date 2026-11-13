[README.md](https://github.com/user-attachments/files/34793395/README.md)
# Pluton CACC cu atacuri cibernetice V2V

Proiect MATLAB/Simulink care simulează un **pluton de 5 vehicule** (1 lider + 4 urmăritori) controlat prin **CACC** (*Cooperative Adaptive Cruise Control*), cu comunicație **V2V** între vehicule consecutive. Pe mesajele V2V se pot injecta live **atacuri cibernetice** (DoS, FDI, Replay), iar fiecare vehicul are un **detector** care verifică plauzibilitatea mesajelor primite. O interfață grafică (UI) permite rularea simulării în timp real, aplicarea atacurilor și urmărirea efectelor.

Documentația detaliată pentru fiecare script este în folderul [`Documentatie/`](Documentatie/):

| Fișier | Rol | Documentație |
|---|---|---|
| [`init_platoon_params.m`](init_platoon_params.m) | Toți parametrii (vehicul, regulatoare, scenariu, atac) | [init_platoon_params.md](Documentatie/init_platoon_params.md) |
| [`fix_platoon_CACC.m`](fix_platoon_CACC.m) | Corecturile de control aplicate o singură dată modelului original | [fix_platoon_CACC.md](Documentatie/fix_platoon_CACC.md) |
| [`add_cyber_to_platoon.m`](add_cyber_to_platoon.m) | Construiește în model injecția de atacuri, detectorul și logarea | [add_cyber_to_platoon.md](Documentatie/add_cyber_to_platoon.md) |
| [`platoon_cyber_ui.m`](platoon_cyber_ui.m) | Interfața live (simulare, atacuri, grafice, alarme) | [platoon_cyber_ui.md](Documentatie/platoon_cyber_ui.md) |
| `Platoon_Year1_CACC_fixed.slx` | Modelul Simulink de lucru | descris mai jos |

---

## 1. Pornire rapidă

Din folderul proiectului, în MATLAB (R2020b sau mai nou):

```matlab
platoon_cyber_ui
```

Atât. UI-ul rulează singur `init_platoon_params`, apoi `add_cyber_to_platoon` (care aduce modelul la structura curentă dacă e nevoie), și deschide fereastra. Apeși **Start**, alegi un atac în panoul 2 și apeși **Aplică atac**.

Pentru simulări fără UI (de exemplu pentru grafice în lucrare):

```matlab
init_platoon_params            % parametrii în workspace
add_cyber_to_platoon           % o singură dată / după modificări de structură
Cyber_AttackType = 2;  Cyber_FDI_Field = 1;  Cyber_FDI_Bias = 10;   % FDI pe poziție, +10 m
out = sim('Platoon_Year1_CACC_fixed','StopTime','40');
plot(out.get('UI_Distance_F1'))
```

> Atenție: în rularea fără UI atacul este activ **de la t = 0**. În UI atacul pornește în momentul în care apeși butonul.

---

## 2. Fluxul scripturilor

```
                 (o singură dată, istoric)
 Platoon_Year1_CACC_modified.slx ──fix_platoon_CACC──▶ Platoon_Year1_CACC_fixed.slx
                                                                  │
 init_platoon_params ─▶ parametri în workspace-ul de bază          │
            │                                                      ▼
            └──────────────▶ add_cyber_to_platoon ─▶ model cu atacuri + detector + logare
                                                                  │
                                    platoon_cyber_ui ◀────────────┘
                     (rulează el însuși init + add_cyber, apoi simulează live)
```

- `fix_platoon_CACC` a fost rulat **o singură dată** pentru a obține modelul corectat. Modelul sursă nu mai există în folder, iar scriptul refuză să suprascrie modelul `_fixed` (care conține acum și partea cyber).
- `add_cyber_to_platoon` este **idempotent**: poate fi rulat oricând; adaugă doar ce lipsește, migrează versiuni vechi ale injecției și salvează modelul doar dacă l-a modificat.

---

## 3. Arhitectura modelului Simulink

### 3.1 Nivelul superior – topologia plutonului

Topologie **predecessor-following**: fiecare urmăritor primește prin V2V starea vehiculului **imediat din fața lui**.

```
 Leader_Vehicle ──▶ V2V_Network ──▶ Follower_1 ──▶ V2V_Network1 ──▶ Follower_2 ──▶ V2V_Network2 ──▶ Follower_3 ──▶ V2V_Network3 ──▶ Follower_4
       │                               │                              │                              │                              │
       └───────────────────────────────┴──────────── Scope_Velocities / Scope_InterDistance / UI_*_Log (To Workspace) ───────────────┘
```

Fiecare vehicul transmite un **bus de stare** cu trei câmpuri: `Position_m`, `Velocity_mps`, `Accel_mps2`.

### 3.2 Dinamica vehiculului (`Vehicle_Dynamics`, identică la toate vehiculele)

```
 a_cmd ─▶ 1/(τs+1) ─▶ a ─▶ ∫ (Int_a2v) ─▶ v ─▶ ∫ (Int_v2x) ─▶ x ─▶ BusCreator_VehState [x, v, a]
```

- `τ = 0.15 s` modelează întârzierea motorului/frânei (*engine lag*).
- Comanda `a_cmd` vine deja limitată la +2 m/s² (accelerație) și −4 m/s² (decelerație) de blocul `Saturation` din regulator (`CACC_Controller/Saturation`, respectiv `Leader_Vehicle/Saturation_Leader`).
- Condițiile inițiale ale integratoarelor sunt pozițiile și viteza de echilibru (vezi §4.1).

### 3.3 Liderul (`Leader_Vehicle`)

```
 Step (v0 → v_cmd_final la t_step) ─▶ eroare viteză ─▶ Kp_PD + Kd_PD · s/(0.05s+1) ─▶ Saturație ─▶ Vehicle_Dynamics_Leader
```

Un regulator PD urmărește o referință de viteză de tip treaptă. Derivata este filtrată (`s/(0.05s+1)`) ca să nu amplifice zgomotul. Din UI se poate schimba live viteza țintă.

### 3.4 Urmăritorul (`Follower_n`)

```
 TransmittedState (V2V) ──┬──▶ CACC_Controller ──▶ a_cmd ──▶ Vehicle_Dynamics ──▶ FollowerState (spre V2V-ul următor)
                          │          ▲  ▲                         │
                          │          │  └──── v_ego ◀── BusSel_Ego ┤
                          │          └─────── x_ego ◀──────────────┘
                          └──▶ BusSel_Leader_Pos ──▶ Calc_InterDist = x_pred − x_ego ──▶ InterDistance (ieșire)
                                                                         Velocity (ieșire) ◀── BusSel_Ego
```

- `InterDistance` = diferența de **poziție** între predecesor și ego (include lungimea vehiculului; contactul are loc la `d ≤ L_VEH = 4 m`).
- `InterDistance` se calculează din poziția primită prin V2V **înainte de injectarea atacului**, deci reprezintă distanța reală (cu cei 20 ms de întârziere ai rețelei), nu distanța pe care o „crede” regulatorul atacat.
- `Follower_1` are o ieșire în plus (`Out1` = distanța dorită), de aceea porturile lui sunt decalate cu 1 față de ceilalți.

### 3.5 Regulatorul CACC (`CACC_Controller`)

```
 BusSel_Leader ─▶ Cyber_RxMux [x;v;a] ─▶ CyberInjector ─▶ Cyber_RxDemux ─┬─ x_pred ─▶ Sum_Gap ─▶ Sum_GapError ─▶ KP_CACC ─┐
        │                ▲                    │                         ├─ v_pred ─▶ Sum_VelError ─────────▶ Kd_CACC ───┼─▶ Sum_CACC ─▶ Saturație ─▶ a_cmd
        │   Cyber_ReplayDelay (Replay)        │                         └─ a_pred ─▶ FF_Filter 1/(h·s+1) ──────────────┘
        │                                     └──▶ CyberDetector ─▶ Cyber_Residual_Log, Cyber_Alarm_Log
        └─ (parametrii atacului: Cyber_Mode, Cyber_Target, Cyber_Index, Cyber_Bias, Cyber_Field, Cyber_DelayValue, Cyber_Threshold)
```

Legea de control:

```
a_cmd = FF(a_pred) + KP_CACC · e + Kd_CACC · (v_pred − v_ego)

e        = (x_pred − x_ego) − d_des
d_des    = (D_DES + L_VEH) + h_CTH · v_ego          (politica CTH)
FF(s)    = 1 / (h_CTH · s + 1)                        (feedforward filtrat)
```

### 3.6 Rețeaua V2V (`V2V_Network`, `V2V_Network1..3`)

Pentru fiecare câmp al mesajului (`x`, `v`, `a`):

```
 câmp ─▶ Transport Delay (20 ms) ─▶ Switch ─▶ mesaj primit
                                      ▲  └─▶ UnitDelay (ultima valoare primită)
          RNG_PktLoss ─▶ PktLoss_Detect┘   (pachet pierdut → se păstrează ultima valoare)
```

- Latența rețelei: **20 ms**.
- Pierderi de pachete aleatoare; la pierdere receptorul păstrează ultimul mesaj valid.
- Fiecare legătură are altă sămânță a generatorului (42, 137, 251, 389), deci pierderile nu sunt corelate.
- Mesajul inițial (în primele 20 ms) este starea inițială a emițătorului (`x0_leader` / `x0_f(n)`, `v0`, `0`).

---

## 4. Partea de control

### 4.1 Politica de spațiere CTH

Distanța dorită crește cu viteza: `d_des = D_DES + L_VEH + h·v`. Cu `D_DES = 10 m`, `L_VEH = 4 m`, `h = 0.6 s`:

| Viteză | Distanță dorită (poziție la poziție) | Spațiu liber între bare |
|---|---|---|
| 0 m/s | 14 m | 10 m |
| 25 m/s | 29 m | 25 m |
| 30 m/s | 32 m | 28 m |

Pozițiile inițiale sunt puse la acest echilibru (`x0_f = x0_leader − n·gap0`), deci simularea pornește fără tranzitoriu.

### 4.2 Stabilitatea de șir (*string stability*)

Un pluton e *string stable* dacă o perturbație a liderului **se atenuează** spre coada plutonului. Trei alegeri o asigură:

1. **CTH în loc de distanță constantă** – în topologia predecessor-following, politica de distanță constantă nu este string stable (Swaroop & Hedrick, 1996).
2. **Feedforward-ul accelerației filtrat cu `1/(h·s+1)`** – garantează `|Γ(jω)| ≤ 1` (Ploeg et al., 2011; Naus et al., 2010).
3. **Condiția `h ≥ 2τ`** (0.6 ≥ 0.3) – verificată automat de `init_platoon_params`.

În simulările de referință (§5.4), perturbațiile produse de atacurile asupra lui F1 nu se propagă la F2: distanța minimă a lui F2 rămâne practic aceeași ca în cazul nominal (în afară de DoS, unde F2 doar oprește în spatele lui F1 la distanța de echilibru).

### 4.3 Parametri

| Parametru | Valoare | Semnificație |
|---|---|---|
| `tau` | 0.15 s | constanta de timp a motorului |
| `h_CTH` | 0.6 s | timpul de gardă |
| `D_DES` | 10 m | distanța liberă la oprire |
| `L_VEH` | 4 m | lungimea vehiculului |
| `KP_CACC` | 0.2 | câștig pe eroarea de distanță |
| `Kd_CACC` | 0.7 | câștig pe eroarea de viteză |
| `Kp_PD`, `Kd_PD` | 0.8, 0.1 | regulatorul liderului |
| `v0` | 0 m/s | viteza inițială |
| `v_cmd_final` | 30 m/s | viteza țintă a liderului |
| `t_step` | 5 s | momentul manevrei liderului |

Solver: `ode23tb`, pas maxim 0.01 s, `RelTol = 1e-4`.

---

## 5. Securitate cibernetică

### 5.1 Modelul de amenințare

Atacatorul controlează **legătura V2V către un singur urmăritor** (ținta, F1–F4) și poate modifica **tot mesajul** primit de acesta: poziție, viteză și accelerație. Atacul este injectat în receptor, după rețea și înaintea regulatorului; vehiculul atacat nu are alt senzor (radar) cu care să compare.

### 5.2 Atacurile implementate (`CyberInjector`)

| Atac | Ce primește regulatorul | Efect tipic |
|---|---|---|
| **DoS** | ultimul mesaj primit înainte de atac, înghețat | ținta crede că predecesorul a rămas pe loc → frânează până la oprire („frână fantomă”), plutonul se rupe |
| **FDI** | mesajul real + un bias pe câmpul ales | bias pozitiv pe poziție/viteză → ținta se apropie periculos; bias negativ → rămâne în urmă |
| **Replay** | mesajul real de acum `Δ` secunde | ținta reacționează cu întârziere; predecesorul pare mai în spate → ținta lasă distanță mai mare |

Parametrii atacului sunt blocuri `Constant` care citesc variabile din workspace, deci se pot schimba **în timpul simulării** (`SimulationCommand update`), inclusiv întârzierea Replay (implementată cu *Variable Time Delay*).

### 5.3 Detectorul (`CyberDetector`)

Verifică dacă mesajul primit respectă fizica:

```
r_v = | d/dt(x_primit) − v_primit |       (poziția evoluează cu viteza raportată?)
r_a = | d/dt(v_primit) − a_primit |       (viteza evoluează cu accelerația raportată?)
```

- Derivatele sunt discrete (pas 0.01 s), iar ambele părți trec prin același filtru `1/(0.1s+1)`, ca reziduul să nu conțină doar întârzierea filtrului.
- **Alarmă** dacă `max(r_v, r_a) > Cyber_ResidualThreshold` (1.0) **continuu 0.2 s**. Pierderile izolate de pachete produc vârfuri scurte și nu declanșează alarma.
- În primele 0.5 s detectorul doar se inițializează.

### 5.4 Rezultate de referință

Scenariu: croazieră la 25 m/s, atac pe F1 la t = 5 s, liderul frânează la 5 m/s la t = 10 s.

| Atac pe F1 | Distanță min. F1 | Distanță min. F2 | Alarmă după |
|---|---|---|---|
| Nominal | 17.0 m | 17.2 m | — (fără alarmă) |
| DoS | 28.1 m (F1 se oprește, distanța crește la 208 m) | 14.0 m | 0.19 s |
| FDI poziție +10 m | **7.0 m** | 17.2 m | 0.19 s |
| FDI poziție −10 m | 27.0 m | 17.2 m | 0.19 s |
| FDI viteză +3 m/s | **6.5 m** | 17.2 m | 0.19 s |
| FDI viteză −3 m/s | 27.5 m | 17.2 m | 0.19 s |
| FDI accelerație +2 m/s² | **7.0 m** | 17.2 m | 0.26 s |
| Replay 0.5 s | 19.5 m | 17.3 m | 0.19 s |
| Replay 2 s | 27.1 m | 17.4 m | 0.19 s |

Fără atac, nici scenariul de pornire 0 → 30 m/s nu produce alarme false.

### 5.5 Limitări

- **Un bias constant este detectat doar la apariție.** După saltul inițial, o poziție falsificată cu +10 m se mișcă exact cu viteza raportată, deci pare plauzibilă; alarma ține ~0.3 s. Oprirea atacului produce și ea o alarmă scurtă (saltul înapoi).
- **Un atacator care falsifică coerent toate câmpurile nu poate fi detectat** fără o măsurătoare independentă (radar).
- Pragul de 1.0 a fost calibrat pe două scenarii; la manevre mai bruște sau mai multe pierderi de pachete poate necesita ajustare (reziduurile sunt salvate în `Cyber_Residual_F1..F4`).
- Detectorul doar semnalează; nu există încă o reacție automată (de exemplu trecere pe ACC sau mărirea distanței).

---

## 6. Interfața grafică

Pe scurt (detalii în [platoon_cyber_ui.md](Documentatie/platoon_cyber_ui.md)):

- **Panoul 1 – Simulare:** Start / Pauză / Stop / Reset, viteza de rulare (1×–10× timp real), viteza țintă a liderului (live) și momentul manevrei.
- **Panoul 2 – Atac:** vehiculul țintă (sau click pe vehicul în vederea de sus), tipul atacului, câmpul și bias-ul FDI, întârzierea Replay, butoanele Aplică / Oprește.
- **Panoul 3 – Stare:** tabel cu viteze, poziții, distanțe; lămpi pentru distanțe (verde / galben / roșu = contact) și pentru detectoare (gri / roșu = alarmă); jurnal de evenimente.
- **Dreapta:** vedere de sus a drumului și grafice live pentru viteze, poziții și distanțe, cu linii verticale la momentele atacurilor.

Semnalele se citesc live prin `RuntimeObject` (vitezele direct din integratoarele `Int_a2v`, pentru că ieșirea `Velocity` vine dintr-un Bus Selector virtual).

---

## 7. Fișiere generate și copii de siguranță

| Fișier | Conținut |
|---|---|
| `Platoon_Year1_CACC_fixed.slx` | modelul de lucru |
| `Platoon_Year1_CACC_fixed_BACKUP_inainte_cyber_v2.slx` | prima versiune cyber (atac doar pe accelerație, Replay cu întârziere fixă, alarmă bazată pe semnalul real) |
| `Platoon_Year1_CACC_fixed_BACKUP_cyber_v2_doar_acceleratie.slx` | a doua versiune (atac doar pe accelerație, detector pe accelerație) |
| `slprj/`, `*.slxc` | cache Simulink, se regenerează automat |

Pentru a reveni la o copie de siguranță, redenumește-o în `Platoon_Year1_CACC_fixed.slx` (scripturile caută modelul după acest nume). Rularea UI-ului o va migra automat la structura curentă a atacurilor.

### Variabile scrise în workspace de simulare

| Variabilă | Conținut |
|---|---|
| `UI_Distance_F1..F4` | distanța reală predecesor–ego (timeseries) |
| `UI_Velocity_F1..F4` | viteza fiecărui urmăritor |
| `Cyber_Residual_F1..F4` | reziduurile `[r_v; r_a]` ale detectorului |
| `Cyber_Alarm_F1..F4` | alarma detectorului (logic) |
| `logsout` | aceleași distanțe/viteze ca *Dataset* (`InterDistance_Fn`, `Velocity_Fn`) |

---

## 8. Referințe

- D. Swaroop, J. K. Hedrick – *String stability of interconnected systems*, IEEE TAC, 1996.
- R. Rajamani – *Vehicle Dynamics and Control*, Springer.
- G. Naus, R. Vugts, J. Ploeg, R. van de Molengraft, M. Steinbuch – *String-stable CACC design and experimental validation*, IEEE TVT, 2010.
- J. Ploeg, B. Scheepers, E. van Nunen, N. van de Wouw, H. Nijmeijer – *Design and experimental evaluation of cooperative adaptive cruise control*, ITSC, 2011.
