# `init_platoon_params.m`

[← Înapoi la prezentarea generală](../README.md)

## Rol

Script care definește **toți parametrii** proiectului și îi pune în workspace-ul de bază MATLAB, de unde îi citesc blocurile modelului Simulink (`Gain`, `Constant`, condiții inițiale etc.). Este singurul loc în care se schimbă valorile numerice ale simulării.

## Când se rulează

- Automat, la pornirea `platoon_cyber_ui` (prin `evalin('base','run(''init_platoon_params.m'')')`).
- Manual, înainte de orice `sim(...)` fără UI, înainte de `add_cyber_to_platoon` și înainte de `fix_platoon_CACC`.

> Scriptul începe cu `clear; clc;` și rulează în workspace-ul de bază, deci **șterge toate variabilele** existente acolo. Orice parametru modificat manual trebuie setat **după** rularea lui.

## Ce face, pe secțiuni

### 1. Dinamica vehiculului

| Variabilă | Valoare | Semnificație |
|---|---|---|
| `tau` | 0.15 s | constanta de timp a întârzierii motorului, `1/(τs+1)` |

### 2. Politica de spațiere CTH

| Variabilă | Valoare | Semnificație |
|---|---|---|
| `h_CTH` | 0.6 s | timpul de gardă |
| `D_DES` | 10 m | distanța liberă dorită la oprire |
| `L_VEH` | 4 m | lungimea vehiculului |

Distanța dorită (de la poziție la poziție) este `d_des = D_DES + L_VEH + h_CTH·v`.

Scriptul verifică condiția suficientă de stabilitate de șir pentru CACC cu feedforward filtrat:

```matlab
if h_CTH < 2*tau
    warning(...)   % risc de instabilitate de șir
else
    fprintf('OK: ...')
end
```

Cu valorile actuale: 0.6 ≥ 0.3, deci condiția este satisfăcută.

### 3. Câștigurile regulatoarelor

| Variabilă | Valoare | Unde se folosește |
|---|---|---|
| `KP_CACC` | 0.2 | urmăritori: câștig pe eroarea de distanță `e = (x_pred − x_ego) − d_des` |
| `Kd_CACC` | 0.7 | urmăritori: câștig pe eroarea de viteză `v_pred − v_ego` |
| `Kp_PD` | 0.8 | lider: proporțional pe eroarea de viteză |
| `Kd_PD` | 0.10 | lider: derivativ (filtrat) pe eroarea de viteză |

### 4. Scenariul liderului

| Variabilă | Valoare | Semnificație |
|---|---|---|
| `v0` | 0 m/s | viteza inițială a tuturor vehiculelor |
| `v_cmd_final` | 30 m/s | viteza țintă a liderului după manevră |
| `t_start` → `t_step` | 5 s | momentul treptei de viteză a liderului |

În model, blocul `Leader_Vehicle/Step` trece de la `v0` la `v_cmd_final` la momentul `t_step`. În workspace variabila se numește `t_step` (așa o folosește blocul).

### 5. Condiții inițiale la echilibru

```matlab
gap0      = (D_DES + L_VEH) + h_CTH * v0;   % 14 m la v0 = 0
x0_leader = 130;
x0_f      = x0_leader - (1:4) * gap0;       % [116 102 88 74]
```

Vehiculele pornesc exact la distanța dorită, deci fără tranzitoriu la t = 0. `x0_leader` și `x0_f` sunt folosite și de rețelele V2V ca mesaj inițial (vezi [add_cyber_to_platoon.md](add_cyber_to_platoon.md)).

> Condițiile inițiale ale integratoarelor de poziție au fost scrise **numeric** în model de `fix_platoon_CACC` (130, 116, 102, 88, 74). Dacă schimbi `x0_leader` sau `v0`, actualizează și `InitialCondition` al blocurilor `Int_v2x` (de exemplu cu expresiile `x0_leader`, `x0_f(n)`).

### 6. Parametrii atacului cibernetic

Valori implicite; UI-ul le suprascrie la fiecare Start și la fiecare aplicare/oprire de atac.

| Variabilă | Implicit | Semnificație |
|---|---|---|
| `Cyber_AttackType` | 0 | 0 nominal, 1 DoS, 2 FDI, 3 Replay |
| `Cyber_TargetVehicle` | 1 | urmăritorul atacat (1–4) |
| `Cyber_FDI_Field` | 3 | câmpul falsificat de FDI: 1 poziție, 2 viteză, 3 accelerație |
| `Cyber_FDI_Bias` | 2 | bias-ul FDI, în unitatea câmpului (m, m/s sau m/s²) |
| `Cyber_ReplayDelay` | 0.5 s | vechimea mesajului retransmis (max. 5 s) |
| `Cyber_ResidualThreshold` | 1.0 | pragul detectorului pe reziduuri |

Aceste variabile **trebuie** să existe înainte de compilare, pentru că blocurile `Constant` din `CACC_Controller` le referă.

### 7. Expunerea în workspace-ul de bază

La final, fiecare parametru este scris explicit cu `assignin('base', ...)`. În mod normal scriptul rulează deja în workspace-ul de bază, dar `assignin` garantează că variabilele ajung acolo și dacă scriptul este apelat din altă funcție.

## Ieșiri

- Variabilele de mai sus în workspace-ul de bază.
- Mesaje în Command Window: verificarea `h ≥ 2τ`, `gap0` și pozițiile inițiale.

## Cum modifici un scenariu

| Vrei să… | Schimbi |
|---|---|
| pornești din croazieră | `v0` (și condițiile inițiale `Int_v2x`, vezi nota de la §5) |
| testezi o frânare a liderului | `v0` mare, `v_cmd_final` mic |
| întârzii manevra | `t_start` |
| faci detectorul mai sensibil / mai tolerant | `Cyber_ResidualThreshold` |
| verifici o altă politică de spațiere | `h_CTH` (atenție la condiția `h ≥ 2τ`) |
