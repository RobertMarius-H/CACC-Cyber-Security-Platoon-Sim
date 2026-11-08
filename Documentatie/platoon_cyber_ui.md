# `platoon_cyber_ui.m`

[← Înapoi la prezentarea generală](../README.md)

## Rol

Interfața grafică a proiectului (App Designer programatic, `uifigure`). Pornește simularea în timp real, permite aplicarea și oprirea atacurilor **în timpul rulării** și afișează live starea plutonului și alarmele detectoarelor.

```matlab
platoon_cyber_ui
```

Necesită MATLAB/Simulink R2020b sau mai nou (`uifigure`, `uigridlayout`, `xline`). Testat pe R2026a.

## Ce se întâmplă la pornire

1. Încarcă modelul `Platoon_Year1_CACC_fixed`.
2. Rulează `init_platoon_params` în workspace-ul de bază (toți parametrii, inclusiv cei ai atacului).
3. `removeUnrealBlocks()` șterge blocurile rămase de la o integrare veche cu Unreal Engine (`Unreal_Scene`, `UE_*`) și salvează modelul **doar dacă a șters ceva**.
4. Rulează `add_cyber_to_platoon`, care aduce modelul la structura curentă a atacurilor dacă e nevoie.
5. Construiește fereastra și pornește un **timer** de 0.1 s care actualizează afișarea.

## Interfața

```
┌─────────────── stânga (330 px) ───────────────┬───────────────────────── dreapta ─────────────────────────┐
│ 1 Simulare                                    │ Fereastră [60 s] Poziții [Absolute]  ☑L ☑F1 ☑F2 ☑F3 ☑F4 │
│   Start  Pauză / Stop  Reset                  ├───────────────────────────────────────────────────────────┤
│   Viteză simulare [1x/2x/5x/10x]              │ Vedere de sus (vehiculele pe drum, click = alege ținta)   │
│   Viteză țintă lider [m/s]  Manevră la t [s]  ├───────────────────────────────────────────────────────────┤
├───────────────────────────────────────────────┤ Viteze  v(t) pentru cele 5 vehicule                       │
│ 2 Atac cibernetic (V2V)                       ├───────────────────────────────────────────────────────────┤
│   Vehicul țintă   Tip atac                    │ Poziții x(t) (absolute sau relative la lider)             │
│   Câmp falsificat / Bias   (FDI)              ├───────────────────────────────────────────────────────────┤
│   Întârziere               (Replay)           │ Distanțe intervehiculare + linia de contact (L_VEH)       │
│   [Aplică atac]  [Oprește atacul]             │                                                           │
│   descrierea atacului, eticheta de stare      │                                                           │
├───────────────────────────────────────────────┤                                                           │
│ 3 Stare pluton                                │                                                           │
│   tabel v / x / gap                           │                                                           │
│   lămpi distanță L-F1 … F3-F4                 │                                                           │
│   lămpi Detector F1 … F4                      │                                                           │
│   jurnal de evenimente                        │                                                           │
└───────────────────────────────────────────────┴───────────────────────────────────────────────────────────┘
```

### Panoul 1 – Simulare

| Control | Efect |
|---|---|
| **Start** | setează `t_step`, `v_cmd_final` și atacul în workspace, apoi pornește simularea cu `StopTime = inf` și *pacing* |
| **Pauză / Continuă** | `SimulationCommand pause` / `continue` |
| **Stop** | oprește simularea (așteaptă max. 10 s să se oprească) |
| **Reset** | oprește, anulează atacul, golește graficele |
| Viteză simulare | `PacingRate` (1×, 2×, 5×, 10× timp real); se poate schimba în timpul rulării |
| Viteză țintă lider | `v_cmd_final`, aplicată **live** |
| Manevră lider la t | `t_step`; implicit valoarea din `init_platoon_params`; blocat în timpul rulării |

### Panoul 2 – Atac cibernetic

| Control | Variabilă | Vizibil la |
|---|---|---|
| Vehicul țintă (F1–F4) | `Cyber_TargetVehicle` | mereu |
| Tip atac (DoS / FDI / Replay) | `Cyber_AttackType` | mereu |
| Câmp falsificat (Poziție / Viteză / Accelerație) | `Cyber_FDI_Field` | FDI |
| Bias (unitatea se schimbă după câmp: m, m/s, m/s²; limite ±20) | `Cyber_FDI_Bias` | FDI |
| Întârziere (0.01–5 s) | `Cyber_ReplayDelay` | Replay |

- Ținta se poate alege și printr-un **click pe vehicul** în vederea de sus. Liderul nu poate fi țintă, pentru că atacul vizează legătura V2V **către** un urmăritor.
- Butonul principal își schimbă textul și culoarea după stare: **Aplică atac** (roșu, niciun atac), **Actualizează atac** (portocaliu, ai schimbat ceva față de atacul activ), **Atac aplicat** (gri, nimic de aplicat).
- Eticheta de jos arată `NOMINAL`, `ATAC ARMAT: …` (aplicat înainte de Start) sau `ATAC ACTIV: …`.

Aplicarea unui atac scrie variabilele în workspace-ul de bază (`pushAttackVars`) și, dacă simularea rulează, trimite `set_param(mdl,'SimulationCommand','update')`. Blocurile `Constant` care referă variabilele își iau noile valori fără oprirea simulării.

### Panoul 3 – Stare pluton

- **Tabel:** viteza, poziția și distanța față de predecesor pentru fiecare vehicul.
- **Lămpi distanță:** verde = normal; galben = `gap < D_DES + L_VEH` (mai aproape decât distanța de echilibru la oprire); roșu = contact (`gap ≤ L_VEH`).
- **Lămpi detector:** gri = mesajele primite de urmăritor sunt plauzibile; roșu = alarmă.
- **Jurnal:** pornire/oprire, atacuri aplicate și oprite, contacte (`t=… s  CONTACT F1-F2`), alarme (`t=… s  ALARMA detector F1`) și revenirea la mesaje plauzibile (`detector F1: mesaj din nou plauzibil`). Păstrează ultimele 80 de linii.

### Graficele

- Fereastră de timp: 30 s, 60 s, 120 s sau tot istoricul.
- Pozițiile pot fi absolute sau relative la lider.
- Bifele L, F1–F4 ascund/arată vehiculele în toate graficele.
- Ținta selectată e desenată cu linie mai groasă, iar în vederea de sus are un contur portocaliu (roșu când e atacată efectiv).
- La fiecare aplicare/oprire de atac apare o linie verticală cu eticheta evenimentului (de exemplu `FDI F1`, `atac oprit`).
- Pentru performanță, fiecare curbă desenează cel mult ~1500 de puncte (subeșantionare).

## Mecanismul live

Simularea nu rulează cu `sim(...)`, ci asincron:

```matlab
set_param(mdl,'SimulationMode','normal','StopTime','inf');
set_param(mdl,'EnablePacing','on','PacingRate',rateDD.Value);   % timp simulat ≈ timp real
set_param(mdl,'SimulationCommand','start');
```

Un `timer` MATLAB (`fixedSpacing`, 0.1 s, `BusyMode = drop`) apelează `onTick`, care:

1. citește `SimulationStatus` și `SimulationTime` (ignoră `t ≤ 0`, când ieșirile nu sunt încă calculate);
2. citește semnalele prin **`RuntimeObject`**-ul blocurilor:

| Semnal | Bloc citit |
|---|---|
| distanța Fn | `Follower_n/Calc_InterDist` (urmărit prin portul `InterDistance`) |
| viteza Fn | `Follower_n/Vehicle_Dynamics/Int_a2v` |
| poziția liderului | `Leader_Vehicle/Vehicle_Dynamics_Leader/Int_v2x` |
| viteza liderului | `Leader_Vehicle/Vehicle_Dynamics_Leader/Int_a2v` |
| alarma Fn | `Follower_n/CACC_Controller/CyberDetector`, ieșirea 2 |

3. reconstruiește pozițiile urmăritorilor din distanțe: `x_i = x_{i−1} − d_i`;
4. adaugă eșantionul în buffer, detectează contactele și alarmele noi și redesenează.

De ce `RuntimeObject` și nu *signal logging*: datele logate sunt disponibile abia la finalul simulării, iar aici simularea rulează la nesfârșit. Abordarea nu depinde de `uitimescope` sau de alte API-uri dependente de versiune.

### De ce vitezele se citesc din integratoare

Ieșirea `Velocity` a fiecărui urmăritor vine dintr-un **Bus Selector**, care este bloc *virtual*. Blocurile virtuale nu au `RuntimeObject`, deci citirea eșua cu „Nu pot citi live: viteza F1…”. Integratorul `Int_a2v` produce exact aceeași valoare și este bloc real. Varianta veche (căutarea portului după nume și urmărirea semnalului prin subsisteme, `findPort` + `getRTO`) rămâne ca rezervă prin `firstOk`.

## Funcții

### Callback-uri (funcții imbricate, au acces la starea UI-ului)

| Funcție | Rol |
|---|---|
| `onStart`, `onPause`, `onStop`, `onReset` | controlul simulării |
| `onRate`, `onVTarget` | pacing și viteza țintă live |
| `onApply`, `onClear` | aplică / oprește atacul |
| `onTypeChange`, `onFieldChange`, `onAttackEdit` | vizibilitatea câmpurilor, unitatea bias-ului, starea butonului |
| `onVehicleClick` | alegerea țintei din vederea de sus |
| `onWindow`, `onPosMode`, `toggleVeh` | opțiunile de afișare |
| `onTick` | bucla live (timer) |
| `acquireSignals` | găsește `RuntimeObject`-urile după pornire; eroare clară dacă distanța sau viteza unui urmăritor nu poate fi citită |
| `pushAttackVars`, `liveUpdate` | scrie atacul în workspace și îl aplică în simulare |
| `refresh`, `updateTable`, `updateLamps`, `updateAlarmLamps`, `drawRoad`, `placeSelection` | desenare |
| `clearData`, `markEvent`, `logMsg`, `setButtons`, `setChip`, `showRow` | utilitare UI |
| `stopSim`, `waitRunning`, `closeApp`, `removeUnrealBlocks` | ciclul de viață al simulării și al ferestrei |

### Funcții locale (la finalul fișierului)

| Funcție | Rol |
|---|---|
| `readSig(s)` | citește valoarea curentă dintr-un `RuntimeObject` (NaN la eroare) |
| `getRTO(blk,port)` | `RuntimeObject` pentru ieșirea `port` a blocului; urmărește semnalul prin subsisteme virtuale până la un bloc real |
| `findPort(blk,pattern,fallback)` | caută ieșirea unui subsistem după numele semnalului sau al blocului `Outport` |
| `firstOk(...)` | primul `RuntimeObject` valid dintre candidați |
| `newBuf`, `newState`, `padLim`, `styleAx`, `onoff`, `yesno` | utilitare |

## Erori frecvente

| Mesaj în jurnal | Cauză / soluție |
|---|---|
| `EROARE la start: Nu pot citi live: viteza F1, …` | blocul sursă nu are `RuntimeObject`; verifică existența `Vehicle_Dynamics/Int_a2v` |
| `Modelul ruleaza deja. Apasa Stop / Reset.` | simularea pornită anterior nu s-a oprit |
| `Update live esuat (parametru netunabil?): …` | un parametru modificat nu poate fi schimbat în timpul rulării |
| `Simularea s-a oprit inainte sa porneasca …` | eroare de compilare; detaliile sunt în Command Window / Diagnostic Viewer |

## Note

- La pornire, UI-ul **poate salva modelul** (prin `add_cyber_to_platoon` sau `removeUnrealBlocks`), dar numai dacă l-a modificat.
- Închiderea ferestrei oprește timerul și simularea.
- Distanța afișată este cea reală, calculată din poziția primită prin V2V **înainte** de injectarea atacului. Sub FDI pe poziție, regulatorul „vede” o distanță falsă, dar graficul arată distanța adevărată.
