# `add_cyber_to_platoon.m`

[← Înapoi la prezentarea generală](../README.md)

## Rol

Funcție care **construiește în modelul Simulink** tot ce ține de securitatea cibernetică și de UI:

1. **injectorul de atacuri** (DoS / FDI / Replay) pe mesajul V2V complet primit de fiecare urmăritor;
2. **detectorul de plauzibilitate** al mesajelor, cu logarea reziduurilor și a alarmelor;
3. **mesajul V2V inițial** corect (starea inițială a emițătorului);
4. **logarea** distanțelor și vitezelor pentru UI și pentru analiză.

Se apelează automat la pornirea `platoon_cyber_ui`. Poate fi rulată și manual, după `init_platoon_params`.

## Proprietăți importante

- **Idempotentă:** la a doua rulare nu schimbă nimic și nu salvează modelul. Testul se face pe flag-ul `Dirty` al modelului.
- **Migrează versiunile vechi:** dacă un `CACC_Controller` nu are blocul `CyberDetector` (model fără atacuri sau cu o versiune anterioară a injecției), șterge tot ce începe cu `Cyber` și reconstruiește structura curentă.
- **Actualizează codul blocurilor MATLAB Function** la fiecare rulare, dacă diferă de cel din script. Codul injectorului și al detectorului trăiește deci în acest fișier `.m`, nu doar în `.slx`.

## Structura construită în fiecare `Follower_n/CACC_Controller`

```
                       ┌──────────────── Cyber_DelayValue ("Cyber_ReplayDelay")
                       ▼
 BusSel_Leader ─▶ Cyber_RxMux ─┬─▶ Cyber_ReplayDelay (Variable Time Delay) ─▶ CyberInjector/2  (uDelayed)
   x, v, a        [x; v; a]    └─────────────────────────────────────────────▶ CyberInjector/1  (u)
                                                                                CyberInjector/3..7 ◀─ Cyber_Mode, Cyber_Target,
                                                                                                      Cyber_Index, Cyber_Bias, Cyber_Field
 CyberInjector/1 (y = mesajul după atac) ─┬─▶ Cyber_RxDemux ─┬─ x ─▶ Sum_Gap/1       (eroarea de distanță)
                                          │                  ├─ v ─▶ Sum_VelError/1  (eroarea de viteză)
                                          │                  └─ a ─▶ FF_Filter/1     (feedforward)
                                          └─▶ CyberDetector/1 ◀── Cyber_Threshold ("Cyber_ResidualThreshold")
                                                 ├─ residual ─▶ Cyber_Residual_Log  → Cyber_Residual_Fn
                                                 └─ alarm    ─▶ Cyber_Alarm_Log     → Cyber_Alarm_Fn
```

| Bloc | Tip | Parametru / rol |
|---|---|---|
| `Cyber_RxMux` | Mux (3) | strânge câmpurile mesajului într-un vector `[x; v; a]` |
| `Cyber_ReplayDelay` | Variable Transport Delay (*Variable time delay*) | vechimea mesajului pentru Replay; max. 5 s; ieșire inițială `[x0 emițător; v0; 0]` |
| `Cyber_DelayValue` | Constant | `Cyber_ReplayDelay` (reglabil live) |
| `Cyber_Mode` | Constant | `Cyber_AttackType` |
| `Cyber_Target` | Constant | `Cyber_TargetVehicle` |
| `Cyber_Index` | Constant | numărul urmăritorului (1–4), fix |
| `Cyber_Bias` | Constant | `Cyber_FDI_Bias` |
| `Cyber_Field` | Constant | `Cyber_FDI_Field` |
| `CyberInjector` | MATLAB Function, discret 0.01 s | aplică atacul |
| `Cyber_RxDemux` | Demux (3) | redistribuie câmpurile către regulator |
| `CyberDetector` | MATLAB Function, discret 0.01 s | verifică plauzibilitatea |
| `Cyber_Threshold` | Constant | `Cyber_ResidualThreshold` |
| `Cyber_Residual_Log`, `Cyber_Alarm_Log` | To Workspace (Timeseries) | `Cyber_Residual_Fn`, `Cyber_Alarm_Fn` |

De ce parametrii sunt blocuri `Constant` care referă variabile din workspace: valorile lor sunt **reglabile în timpul simulării**. UI-ul schimbă variabila și trimite `set_param(mdl,'SimulationCommand','update')`, iar atacul se modifică fără oprirea simulării. Din același motiv, întârzierea Replay vine pe un port (Variable Time Delay) și nu ca parametru al unui Transport Delay obișnuit, al cărui `DelayTime` nu poate fi schimbat în timpul rulării.

## Injectorul (`CyberInjector`)

```matlab
function y = cyber(u,uDelayed,mode,target,index,bias,field)
% u = [x; v; a] mesajul primit de la predecesor
persistent uLast
if isempty(uLast), uLast = u; end
y = u;
active = target == index;              % atacul vizează acest urmăritor?
isDoS = active && mode == 1;
if isDoS
    y = uLast;                         % DoS: ultimul mesaj primit, înghețat
elseif active && mode == 2
    k = min(max(round(field),1),3);
    y(k) = u(k) + bias;                % FDI: bias pe câmpul ales
elseif active && mode == 3
    y = uDelayed;                      % Replay: mesajul de acum Δ secunde
end
if ~isDoS, uLast = u; end              % memoria se actualizează doar cât nu e DoS
end
```

- **DoS = păstrarea ultimului mesaj.** Același comportament îl are rețeaua V2V la pierderea unui pachet (`UnitDelay`), deci DoS-ul arată ca o pierdere de pachete continuă.
- Blocul este **discret (0.01 s, rata V2V)**. Simulink nu permite variabile `persistent` într-un MATLAB Function cu timp de eșantionare continuu.
- Toate cele 4 injectoare primesc aceiași parametri; doar cel cu `index == target` este activ.

## Detectorul (`CyberDetector`)

Ideea: într-un mesaj real, cele trei câmpuri sunt legate fizic. Poziția evoluează cu viteza raportată, iar viteza cu accelerația raportată. Un mesaj atacat încalcă de obicei aceste relații, cel puțin în momentul în care atacul începe.

```matlab
function [residual,alarm] = detect(m,threshold)
persistent prev f count n
Ts = 0.01; Tf = 0.1; k = Ts/(Tf + Ts);
if isempty(prev)
    prev = m; f = [m(2); m(2); m(3); m(3)]; count = 0; n = 0;
end
n = n + 1;
raw = [(m(1) - prev(1))/Ts; m(2); (m(2) - prev(2))/Ts; m(3)];   % [dx/dt; v; dv/dt; a]
f = f + k*(raw - f);                                               % filtru 1/(Tf s + 1)
prev = m;
residual = [abs(f(1) - f(2)); abs(f(3) - f(4))];                   % [r_v; r_a]
if n > 50 && max(residual) > threshold, count = count + 1; else, count = 0; end
alarm = count >= 20;
end
```

Decizii de proiectare:

| Decizie | Motiv |
|---|---|
| derivare și filtrare **discrete**, în interiorul blocului | filtrele continue `s/(0.1s+1)` porneau din stare 0 și vedeau la t = 0 un „salt” de la 0 la 130 m, cu reziduu de ordinul miilor |
| **același filtru** pe ambele părți ale comparației | reziduul nu mai conține întârzierea filtrului, doar incoerența reală |
| inițializare cu primul mesaj | fără tranzitoriu artificial la pornire |
| **persistență 0.2 s** (20 de pași) | pierderile izolate de pachete dau vârfuri de câțiva m/s, dar scurte |
| **încălzire 0.5 s** (`n > 50`) | în primele 20 ms rețeaua livrează o poziție constantă, deși vehiculul are deja viteza `v0` |
| detectorul vede mesajul **după** atac | e exact ce vede receptorul; nu are acces la semnalul real |

Comparat cu versiunea anterioară (alarmă calculată ca `|mesaj atacat − mesaj real|`), detectorul actual nu mai folosește informații pe care vehiculul nu le-ar avea.

## Mesajul V2V inițial

Pentru fiecare legătură (`V2V_Network` … `V2V_Network3`) și fiecare câmp, scriptul setează:

| Bloc | Parametru | Valoare |
|---|---|---|
| `TD_Position_m` / `UnitDelay_Position_m` | `InitialOutput` / `InitialCondition` | `x0_leader`, `x0_f(1)`, `x0_f(2)`, `x0_f(3)` (emițătorul legăturii) |
| `TD_Velocity_mps` / `UnitDelay_Velocity_mps` | idem | `v0` |
| `TD_Accel_mps2` / `UnitDelay_Accel_mps2` | idem | `0` |

Fără această corectură, primele 20 ms (întârzierea rețelei) conțineau zerouri: distanța măsurată ieșea negativă la t = 0 (−104 m pentru F1), iar un DoS armat înainte de Start ar fi înghețat un mesaj nul.

## Logarea pentru UI

Pentru fiecare urmăritor:

- blocuri **To Workspace** la nivelul superior: `UI_Distance_Log_Fn` → `UI_Distance_Fn` și `UI_Velocity_Log_Fn` → `UI_Velocity_Fn`;
- **signal logging** (`logsout`, Dataset) pe porturile `InterDistance_Fn` și `Velocity_Fn`.

Porturile diferă: `Follower_1` are distanța pe portul 3 și viteza pe 4 (are o ieșire în plus, distanța dorită), ceilalți pe 2 și 3.

## Funcțiile locale

| Funcție | Ce face |
|---|---|
| `removeCyber(c)` | șterge blocurile `Cyber*` și liniile lor, liniile de ieșire din `BusSel_Leader` și segmentele rămase neconectate |
| `buildCyber(c,k,x0Tx)` | construiește structura de mai sus pentru urmăritorul `k` |
| `injectorScript()`, `detectorScript()` | întorc codul celor două blocuri MATLAB Function |
| `setScript(blk,script)` | scrie codul în bloc doar dacă diferă și setează blocul discret la 0.01 s |
| `fieldPorts(busSel)` | găsește după nume (`pos`, `vel`, `acc`) porturile `BusSel_Leader` pentru x, v, a |
| `setIfDiff(blk,param,value)` | `set_param` doar dacă valoarea diferă (păstrează modelul ne-*Dirty*) |
| `hasBlock(parent,name)` | există blocul `name` direct în `parent`? |

## Verificare

Testat cu MATLAB R2026a pe copii ale modelului:

- migrare reușită din ambele versiuni anterioare (backup-urile din folder);
- compilare fără erori; a doua rulare lasă modelul ne-modificat;
- 9 scenarii de atac plus 2 scenarii nominale, cu rezultatele din [README §5.4](../README.md#54-rezultate-de-referință).

## Limitări

- Un FDI cu **bias constant** este detectat doar la apariție și la dispariție; între timp mesajul falsificat este coerent.
- Un atacator care falsifică **coerent toate câmpurile** nu poate fi detectat fără un senzor independent (radar).
- `Cyber_ResidualThreshold = 1.0` a fost calibrat pe două scenarii nominale.
- Pe nivelul `CACC_Controller`, pozițiile blocurilor sunt alese fix și liniile cu *autorouting*; diagrama poate necesita aranjare manuală pentru capturi de ecran.
