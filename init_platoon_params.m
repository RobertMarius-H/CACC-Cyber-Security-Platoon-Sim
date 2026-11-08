clear; clc;

%% --- Dinamica vehiculului (din model) ---
tau   = 0.15;        % constanta de timp a actuatorului/motorului [s]  (Engine_Lag_TF = 1/(tau*s+1))

%% --- Politica de spațiere: TIMP DE GARDĂ CONSTANT (CTH) ---
% d_des,i = D_DES + h_CTH * v_i   (gardă),   din temă: d0=10 m, h=0.6 s
h_CTH = 0.6;         % timp de gardă [s]  (h_i din temă)
D_DES = 10;          % distanța la oprire / gardă minimă [m]  (d0 din temă)
L_VEH = 4;           % lungimea vehiculului [m]  (ipoteză rezonabilă; ajustați la nevoie)

% Verificare condiție de stabilitate de șir (suficientă, abordare PD+FF):
% pentru CACC cu feedforward filtrat 1/(h*s+1) este suficient h >= 2*tau.
if h_CTH < 2*tau
    warning('h_CTH = %.2f s < 2*tau = %.2f s : risc de instabilitate de șir!', h_CTH, 2*tau);
else
    fprintf('OK: h_CTH = %.2f s >= 2*tau = %.2f s  -> condiție de stabilitate de șir satisfăcută.\n', h_CTH, 2*tau);
end

%   a_cmd = FF(a_pred) + KP_CACC*e + Kd_CACC*edot
% cu e = (x_pred - x_ego) - (L_VEH + D_DES + h*v_ego)
KP_CACC = 0.2;       % gain proporțional pe eroarea de spațiere
Kd_CACC = 0.7;       % gain "derivativ" pe eroarea de viteză (v_pred - v_ego)

%% --- Gains regulator LEADER (PD pe eroarea de viteză) ---
Kp_PD = 0.8;
Kd_PD = 0.10;

%% --- Scenariul liderului (referință de viteză) ---
v0           = 0;   % viteza inițială a întregului pluton [m/s] (pornire din staționare)
v_cmd_final  = 30;   % viteza țintă a liderului după manevră [m/s] (0 -> 30 m/s)
t_start      = 5;    % momentul manevrei liderului [s] (și valoarea implicită din UI)

%% --- Condiții inițiale de poziție la ECHILIBRU CTH ---
% gardă de echilibru (diferență de poziție) la v0:
gap0      = (D_DES + L_VEH) + h_CTH * v0;     % [m]
x0_leader = 130;                              % poziția inițială a liderului [m]
x0_f      = x0_leader - (1:4) * gap0;         % pozițiile inițiale follower 1..4

fprintf('Gardă de echilibru la v0=%g m/s: gap0 = %g m\n', v0, gap0);
fprintf('Poziții inițiale: Leader=%g | F1=%g | F2=%g | F3=%g | F4=%g\n', ...
        x0_leader, x0_f(1), x0_f(2), x0_f(3), x0_f(4));

%% --- Atac cibernetic V2V (valori implicite; UI-ul le suprascrie) ---
% Blocurile Constant din CACC_Controller citesc aceste variabile, deci
% trebuie definite înainte de compilare chiar dacă nu se rulează UI-ul.
Cyber_AttackType        = 0;    % 0 nominal | 1 DoS | 2 FDI | 3 Replay
Cyber_TargetVehicle     = 1;    % follower-ul atacat (1..4)
Cyber_FDI_Field         = 3;    % câmpul falsificat de FDI: 1 poziție | 2 viteză | 3 accelerație
Cyber_FDI_Bias          = 2;    % bias FDI, în unitatea câmpului [m | m/s | m/s^2]
Cyber_ReplayDelay       = 0.5;  % întârziere Replay [s] (max. 5 s)
Cyber_ResidualThreshold = 1.0;  % prag alarmă pe reziduurile |dx/dt - v|, |dv/dt - a|

%% Expunere în baza de lucru (pentru blocurile care le folosesc ca string)
assignin('base','tau',tau);
assignin('base','h_CTH',h_CTH);
assignin('base','D_DES',D_DES);
assignin('base','L_VEH',L_VEH);
assignin('base','KP_CACC',KP_CACC);
assignin('base','Kd_CACC',Kd_CACC);
assignin('base','Kp_PD',Kp_PD);
assignin('base','Kd_PD',Kd_PD);
assignin('base','v0',v0);
assignin('base','v_cmd_final',v_cmd_final);
assignin('base','t_step',t_start);
assignin('base','x0_leader',x0_leader);   % folosite de blocurile V2V (mesajul inițial)
assignin('base','x0_f',x0_f);
assignin('base','Cyber_AttackType',Cyber_AttackType);
assignin('base','Cyber_TargetVehicle',Cyber_TargetVehicle);
assignin('base','Cyber_FDI_Field',Cyber_FDI_Field);
assignin('base','Cyber_FDI_Bias',Cyber_FDI_Bias);
assignin('base','Cyber_ReplayDelay',Cyber_ReplayDelay);
assignin('base','Cyber_ResidualThreshold',Cyber_ResidualThreshold);
