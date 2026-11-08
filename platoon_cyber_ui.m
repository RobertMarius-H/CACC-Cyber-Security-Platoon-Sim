function platoon_cyber_ui
% PLATOON_CYBER_UI  Interfata live pentru plutonul CACC + atacuri cyber V2V.
%
%  - alegi vehiculul tinta (dropdown SAU click pe vehicul in vederea de sus)
%  - alegi atacul (DoS / FDI / Replay) si il aplici / opresti in timpul rularii
%  - grafice live: viteze, pozitii, distante intervehiculare (5 vehicule)
%
% Mecanism live: simularea porneste cu set_param(mdl,'SimulationCommand','start'),
% rulata cu pacing (timp simulat ~ timp real), iar un timer MATLAB citeste
% semnalele prin Simulink RuntimeObject. Nu folosim uitimescope / bind /
% simulation(...), deci nu depindem de versiunea de MATLAB sau de semnale logate.
%
% Necesita: MATLAB/Simulink R2020b+ (uifigure, xline). Model: Platoon_Year1_CACC_fixed

mdl = 'Platoon_Year1_CACC_fixed';

%% ===== 1. Pregatire model (la fel ca in versiunea anterioara) =====
if ~bdIsLoaded(mdl), load_system(mdl); end
evalin('base','run(''init_platoon_params.m'')');
removeUnrealBlocks();
if exist('add_cyber_to_platoon','file'), add_cyber_to_platoon; end

L_VEH = evalin('base','L_VEH');
D_DES = evalin('base','D_DES');
x0    = [evalin('base','x0_leader'), reshape(evalin('base','x0_f'),1,[])];  % 1x5
vCmd0 = evalin('base','v_cmd_final');
tStep0 = evalin('base','t_step');

%% ===== 2. Constante si stare =====
names    = {'Lider','Follower 1','Follower 2','Follower 3','Follower 4'};
short    = {'L','F1','F2','F3','F4'};
gapNames = {'L-F1','F1-F2','F2-F3','F3-F4'};
typeNames = {'DoS','FDI','Replay'};
fieldNames = {'Pozitie','Viteza','Acceleratie'};   % campurile mesajului V2V atacate de FDI
fieldUnits = {'m','m/s','m/s^2'};
colors = [0.15 0.15 0.15;  0.00 0.45 0.74;  0.85 0.33 0.10;  0.30 0.65 0.20;  0.55 0.20 0.65];

buf   = newBuf();
state = newState(x0);
sig   = struct('d',{{}},'v',{{}},'al',{{}},'xL',[],'vL',[]);
tmr = []; running = false; paused = false;
atk = struct('type',0,'target',1,'field',3,'bias',2,'delay',0.5);   % atacul APLICAT (type 0 = nominal)
evLines = gobjects(0);
contactPrev = false(1,4); alarmPrev = false(1,4);
winSec = 60; relMode = false; visible = true(1,5);
lastErrMsg = '';

%% ===== 3. Interfata =====
fig = uifigure('Name','Platoon CACC - Cybersecurity','Position',[30 30 1400 860], ...
    'CloseRequestFcn',@closeApp);
root = uigridlayout(fig,[1 2]); root.ColumnWidth = {330,'1x'}; root.Padding = [8 8 8 8];

% ---------- Coloana stanga ----------
left = uigridlayout(root,[3 1]); left.RowHeight = {205,340,330}; left.Padding = [0 0 0 0];
left.Scrollable = 'on'; left.RowSpacing = 6;

% -- Panou 1: simulare
p1 = uipanel(left,'Title','1  Simulare');
g1 = uigridlayout(p1,[5 2]); g1.RowHeight = {30,30,28,28,28}; g1.ColumnWidth = {'1x','1x'};
g1.Padding = [8 6 8 6]; g1.RowSpacing = 5;
btnStart = uibutton(g1,'Text','Start','FontWeight','bold','BackgroundColor',[0.20 0.62 0.30], ...
    'FontColor','w','ButtonPushedFcn',@onStart);
btnPause = uibutton(g1,'Text','Pauza','Enable','off','ButtonPushedFcn',@onPause);
btnStop  = uibutton(g1,'Text','Stop','Enable','off','ButtonPushedFcn',@onStop);
btnReset = uibutton(g1,'Text','Reset','ButtonPushedFcn',@onReset);
uilabel(g1,'Text','Viteza simulare');
rateDD = uidropdown(g1,'Items',{'1x','2x','5x','10x'},'ItemsData',[1 2 5 10],'Value',1, ...
    'ValueChangedFcn',@onRate);
uilabel(g1,'Text','Viteza tinta lider [m/s]');
vTgt = uieditfield(g1,'numeric','Value',vCmd0,'Limits',[0 60],'ValueChangedFcn',@onVTarget);
uilabel(g1,'Text','Manevra lider la t [s]');
tStepF = uieditfield(g1,'numeric','Value',tStep0,'Limits',[0 1e4]);

% -- Panou 2: atac
p2 = uipanel(left,'Title','2  Atac cibernetic (V2V)');
g2 = uigridlayout(p2,[8 2]); g2.RowHeight = {28,28,28,28,28,32,66,36}; g2.ColumnWidth = {112,'1x'};
g2.Padding = [8 6 8 6]; g2.RowSpacing = 5;
lbl = uilabel(g2,'Text','Vehicul tinta'); lbl.Tooltip = 'Follower-ul al carui mesaj V2V (de la predecesor) este atacat';
tgtDD = uidropdown(g2,'Items',names(2:5),'ItemsData',1:4,'Value',1,'ValueChangedFcn',@onAttackEdit);
uilabel(g2,'Text','Tip atac');
typeDD = uidropdown(g2,'Items',typeNames,'ItemsData',[1 2 3],'Value',2,'ValueChangedFcn',@onTypeChange);
lblField = uilabel(g2,'Text','Camp falsificat');
fieldDD = uidropdown(g2,'Items',fieldNames,'ItemsData',[1 2 3],'Value',3,'ValueChangedFcn',@onFieldChange);
lblBias = uilabel(g2,'Text','Bias [m/s^2]');
biasF = uieditfield(g2,'numeric','Value',2,'Limits',[-20 20],'ValueChangedFcn',@onAttackEdit);
lblDelay = uilabel(g2,'Text','Intarziere [s]');
delayF = uieditfield(g2,'numeric','Value',0.5,'Limits',[0.01 5],'ValueChangedFcn',@onAttackEdit);
btnApply = uibutton(g2,'Text','Aplica atac','FontWeight','bold','BackgroundColor',[0.80 0.25 0.20], ...
    'FontColor','w','ButtonPushedFcn',@onApply);
btnClear = uibutton(g2,'Text','Opreste atacul','ButtonPushedFcn',@onClear);
descLbl = uilabel(g2,'Text','','WordWrap','on','VerticalAlignment','top','FontSize',11);
descLbl.Layout.Row = 7; descLbl.Layout.Column = [1 2];
chip = uilabel(g2,'Text','NOMINAL - fara atac','HorizontalAlignment','center','FontWeight','bold', ...
    'BackgroundColor',[0.80 0.93 0.82]);
chip.Layout.Row = 8; chip.Layout.Column = [1 2];

% -- Panou 3: stare
p3 = uipanel(left,'Title','3  Stare pluton');
g3 = uigridlayout(p3,[3 1]); g3.RowHeight = {134,80,'1x'}; g3.Padding = [6 4 6 4]; g3.RowSpacing = 4;
tbl = uitable(g3,'ColumnName',{'Vehicul','v [m/s]','x [m]','gap [m]'},'RowName',{}, ...
    'ColumnWidth',{70,58,66,54},'FontSize',11);
lg = uigridlayout(g3,[4 4]); lg.RowHeight = {22,16,22,16}; lg.Padding = [0 0 0 0]; lg.RowSpacing = 0;
lamp = gobjects(1,4); alarmLamp = gobjects(1,4);
for k = 1:4, lamp(k) = uilamp(lg,'Color',[0.2 0.7 0.3]); end
for k = 1:4
    l = uilabel(lg,'Text',gapNames{k},'HorizontalAlignment','center','FontSize',10);
    l.Tooltip = 'verde: ok | galben: gap < D\_DES + L\_VEH | rosu: contact (gap <= L\_VEH)';
end
for k = 1:4, alarmLamp(k) = uilamp(lg,'Color',[0.75 0.75 0.75]); end
for k = 1:4
    l = uilabel(lg,'Text',sprintf('Detector F%d',k),'HorizontalAlignment','center','FontSize',10);
    l.Tooltip = 'gri: mesaj V2V plauzibil | rosu: alarma (d/dt x ~ v sau d/dt v ~ a incalcate > 0.2 s)';
end
logBox = uitextarea(g3,'Editable','off','Value',{'Pregatit. Apasa Start.'},'FontSize',10);

% ---------- Coloana dreapta ----------
right = uigridlayout(root,[5 1]); right.RowHeight = {34,130,'1x','1x','1x'};
right.Padding = [0 0 0 0]; right.RowSpacing = 4;

tb = uigridlayout(right,[1 10]); tb.ColumnWidth = {62,78,55,175,50,50,50,50,50,'1x'};
tb.Padding = [0 2 0 2];
uilabel(tb,'Text','Fereastra:','HorizontalAlignment','right');
winDD = uidropdown(tb,'Items',{'30 s','60 s','120 s','Tot'},'ItemsData',[30 60 120 Inf],'Value',60, ...
    'ValueChangedFcn',@onWindow);
uilabel(tb,'Text','Pozitii:','HorizontalAlignment','right');
posDD = uidropdown(tb,'Items',{'Absolute','Relativ la lider'},'ItemsData',{'abs','rel'},'Value','abs', ...
    'ValueChangedFcn',@onPosMode);
for i = 1:5
    uicheckbox(tb,'Text',short{i},'Value',true,'FontColor',colors(i,:),'FontWeight','bold', ...
        'ValueChangedFcn',@(s,~) toggleVeh(i,s.Value));
end
uilabel(tb,'Text','Click pe un follower in vederea de sus = alege tinta','FontAngle','italic', ...
    'FontColor',[0.45 0.45 0.45],'HorizontalAlignment','right');

axRoad = uiaxes(right); axV = uiaxes(right); axX = uiaxes(right); axD = uiaxes(right);
styleAx(axRoad,'Vedere de sus'); styleAx(axV,'Viteze'); styleAx(axX,'Pozitii'); styleAx(axD,'Distante intervehiculare');
ylabel(axV,'v [m/s]'); ylabel(axX,'x [m]'); ylabel(axD,'gap [m]'); xlabel(axD,'Timp simulat [s]');

% vedere de sus
axRoad.YLim = [-3 3]; axRoad.YTick = []; xlabel(axRoad,'Pozitie [m]');
rectangle(axRoad,'Position',[-1e5 -1.6 2e5 3.2],'FaceColor',[0.93 0.93 0.93],'EdgeColor','none','PickableParts','none');
yline(axRoad,0,'--','Color',[0.70 0.70 0.70]);
rect = gobjects(1,5); lab = gobjects(1,5);
for i = 1:5
    rect(i) = rectangle(axRoad,'Position',[x0(i)-L_VEH/2 -0.9 L_VEH 1.8],'FaceColor',colors(i,:), ...
        'EdgeColor',[0.1 0.1 0.1],'LineWidth',1,'Curvature',[0.3 0.3], ...
        'ButtonDownFcn',@(~,~) onVehicleClick(i));
    lab(i) = text(axRoad,x0(i),2.0,short{i},'HorizontalAlignment','center','FontWeight','bold', ...
        'Color',colors(i,:),'HitTest','off','PickableParts','none');
end
selRect = rectangle(axRoad,'Position',[0 0 1 1],'EdgeColor',[0.95 0.60 0.10],'LineWidth',3, ...
    'FaceColor','none','Curvature',[0.3 0.3],'PickableParts','none');
axRoad.XLim = [min(x0)-30, max(x0)+30];

% grafice
hV = gobjects(1,5); hX = gobjects(1,5); hD = gobjects(1,4);
for i = 1:5
    hV(i) = plot(axV,NaN,NaN,'Color',colors(i,:),'LineWidth',1.6,'DisplayName',names{i});
    hX(i) = plot(axX,NaN,NaN,'Color',colors(i,:),'LineWidth',1.6,'DisplayName',names{i});
end
for i = 1:4
    hD(i) = plot(axD,NaN,NaN,'Color',colors(i+1,:),'LineWidth',1.6,'DisplayName',gapNames{i});
end
yline(axD,L_VEH,'--','Contact','Color',[0.80 0.10 0.10],'LabelHorizontalAlignment','left', ...
    'LabelVerticalAlignment','bottom');
legend(axV,hV,'Location','southeast','Orientation','horizontal');
legend(axD,hD,'Location','northeast','Orientation','horizontal');
axV.YLim = [-1 35]; axX.YLim = [min(x0)-10 max(x0)+10]; axD.YLim = [0 40];
axV.XLim = [0 winSec]; axX.XLim = [0 winSec]; axD.XLim = [0 winSec];

onTypeChange();      % descriere + vizibilitate parametri
updateEmphasis();
clearData();
setChip();

tmr = timer('ExecutionMode','fixedSpacing','Period',0.1,'BusyMode','drop','TimerFcn',@onTick);
start(tmr);

%% ================= Callback-uri: simulare =================
    function onStart(~,~)
        try
            if ~strcmp(get_param(mdl,'SimulationStatus'),'stopped')
                logMsg('Modelul ruleaza deja. Apasa Stop / Reset.'); return
            end
            clearData();
            logMsg('Se compileaza modelul...'); drawnow;
            assignin('base','t_step',tStepF.Value);
            try, set_param([mdl '/Leader_Vehicle/Step'],'Time','t_step'); catch, end
            assignin('base','v_cmd_final',vTgt.Value);
            pushAttackVars();
            set_param(mdl,'SimulationMode','normal','StopTime','inf');
            try, set_param(mdl,'FastRestart','off'); catch, end
            try
                set_param(mdl,'EnablePacing','on','PacingRate',rateDD.Value);
            catch ME
                logMsg(['Pacing indisponibil: ' ME.message]);
            end
            set_param(mdl,'SimulationCommand','start');
            waitRunning();
            acquireSignals();
            running = true; paused = false; setButtons('running');
            logMsg('Simulare pornita.');
            if atk.type > 0, markEvent(sprintf('%s %s',typeNames{atk.type},short{atk.target+1}),[0.85 0.1 0.1]); end
        catch ME
            running = false; setButtons('idle');
            try, set_param(mdl,'SimulationCommand','stop'); catch, end
            logMsg(['EROARE la start: ' ME.message]);
        end
    end

    function onPause(~,~)
        if ~running, return; end
        try
            if ~paused
                set_param(mdl,'SimulationCommand','pause'); paused = true; setButtons('paused');
            else
                set_param(mdl,'SimulationCommand','continue'); paused = false; setButtons('running');
            end
        catch ME
            logMsg(['Pauza esuata: ' ME.message]);
        end
    end

    function onStop(~,~)
        stopSim(); running = false; paused = false; setButtons('idle'); logMsg('Simulare oprita.');
    end

    function onReset(~,~)
        stopSim(); running = false; paused = false; setButtons('idle');
        atk.type = 0; pushAttackVars();
        clearData(); setChip(); onAttackEdit();
        logBox.Value = {'Resetat: vehicule stationare, fara atac.'};
    end

    function onRate(~,~)
        if running
            try, set_param(mdl,'PacingRate',rateDD.Value); catch, end
        end
    end

    function onVTarget(~,~)
        assignin('base','v_cmd_final',vTgt.Value); liveUpdate();
    end

%% ================= Callback-uri: atac =================
    function onApply(~,~)
        atk.type = typeDD.Value; atk.target = tgtDD.Value; atk.field = fieldDD.Value;
        atk.bias = biasF.Value;  atk.delay  = delayF.Value;
        pushAttackVars(); liveUpdate(); setChip(); onAttackEdit();
        lbl_ = attackText();
        logMsg(['ATAC aplicat: ' lbl_]);
        if running, markEvent(sprintf('%s %s',typeNames{atk.type},short{atk.target+1}),[0.85 0.1 0.1]); end
    end

    function onClear(~,~)
        wasActive = atk.type > 0;
        atk.type = 0; pushAttackVars(); liveUpdate(); setChip(); onAttackEdit();
        logMsg('Atac oprit - comunicatie nominala.');
        if running && wasActive, markEvent('atac oprit',[0.4 0.4 0.4]); end
    end

    function onTypeChange(~,~)
        t = typeDD.Value;
        showRow(lblField,fieldDD,t == 2,3);
        showRow(lblBias,biasF,t == 2,4);
        showRow(lblDelay,delayF,t == 3,5);
        switch t
            case 1, descLbl.Text = 'DoS: mesajele V2V ale predecesorului (pozitie, viteza, acceleratie) sunt blocate; follower-ul ramane pe ultimul mesaj primit si franeaza spre o pozitie inghetata.';
            case 2, descLbl.Text = 'FDI: se adauga un bias la campul ales din mesajul predecesorului (pozitie -> gap fals, viteza -> eroare de viteza falsa, acceleratie -> feedforward fals).';
            case 3, descLbl.Text = 'Replay: follower-ul primeste mesajul complet vechi al predecesorului (intarziat cu valoarea setata).';
        end
        onAttackEdit();
    end

    function onFieldChange(~,~)
        lblBias.Text = sprintf('Bias [%s]',fieldUnits{fieldDD.Value});
        onAttackEdit();
    end

    function onAttackEdit(~,~)
        updateEmphasis();
        if atk.type == 0
            btnApply.Text = 'Aplica atac'; btnApply.BackgroundColor = [0.80 0.25 0.20];
        elseif atk.type ~= typeDD.Value || atk.target ~= tgtDD.Value || ...
               (typeDD.Value == 2 && (atk.bias ~= biasF.Value || atk.field ~= fieldDD.Value)) || ...
               (typeDD.Value == 3 && atk.delay ~= delayF.Value)
            btnApply.Text = 'Actualizeaza atac'; btnApply.BackgroundColor = [0.90 0.55 0.10];
        else
            btnApply.Text = 'Atac aplicat'; btnApply.BackgroundColor = [0.55 0.55 0.55];
        end
    end

    function onVehicleClick(i)
        if i == 1
            logMsg('Atacul vizeaza legatura V2V catre un follower (F1-F4), nu liderul.');
            return
        end
        tgtDD.Value = i-1; onAttackEdit();
        refreshRoadOnly();
    end

    function pushAttackVars()
        assignin('base','Cyber_AttackType',atk.type);
        assignin('base','Cyber_TargetVehicle',atk.target);
        assignin('base','Cyber_FDI_Field',atk.field);
        assignin('base','Cyber_FDI_Bias',atk.bias);
        assignin('base','Cyber_ReplayDelay',atk.delay);
    end

    function liveUpdate()
        if running
            try
                set_param(mdl,'SimulationCommand','update');
            catch ME
                logMsg(['Update live esuat (parametru netunabil?): ' ME.message]);
            end
        end
    end

    function s = attackText()
        switch atk.type
            case 1, s = sprintf('DoS -> Follower %d',atk.target);
            case 2, s = sprintf('FDI %s %+g %s -> Follower %d',lower(fieldNames{atk.field}), ...
                                atk.bias,fieldUnits{atk.field},atk.target);
            case 3, s = sprintf('Replay (%.2f s) -> Follower %d',atk.delay,atk.target);
            otherwise, s = 'nominal';
        end
    end

    function setChip()
        if atk.type == 0
            chip.Text = 'NOMINAL - fara atac'; chip.BackgroundColor = [0.80 0.93 0.82]; chip.FontColor = [0 0.3 0];
        else
            if running, pre = 'ATAC ACTIV: '; else, pre = 'ATAC ARMAT: '; end
            chip.Text = [pre attackText()]; chip.BackgroundColor = [0.98 0.80 0.78]; chip.FontColor = [0.6 0 0];
        end
    end

%% ================= Callback-uri: afisare =================
    function onWindow(~,~), winSec = winDD.Value; refresh(); end
    function onPosMode(~,~)
        relMode = strcmp(posDD.Value,'rel');
        if relMode, ylabel(axX,'x - x_{lider} [m]'); else, ylabel(axX,'x [m]'); end
        refresh();
    end
    function toggleVeh(i,val)
        visible(i) = val; st = onoff(val);
        hV(i).Visible = st; hX(i).Visible = st; rect(i).Visible = st; lab(i).Visible = st;
        if i >= 2, hD(i-1).Visible = st; end
        refresh();
    end

    function updateEmphasis()
        tgt = tgtDD.Value + 1;
        for i = 1:5
            w = 1.6; if i == tgt, w = 3.2; end
            hV(i).LineWidth = w; hX(i).LineWidth = w;
        end
        for i = 1:4
            w = 1.6; if i == tgtDD.Value, w = 3.2; end
            hD(i).LineWidth = w;
        end
    end

%% ================= Timer: citire live si desenare =================
    function onTick(~,~)
        if ~isvalid(fig), return; end
        try
            st = get_param(mdl,'SimulationStatus');
            if strcmp(st,'stopped')
                if running
                    running = false; paused = false; setButtons('idle'); setChip();
                    logMsg('Simularea s-a oprit.');
                end
                return
            end
            if ~running || ~any(strcmp(st,{'running','paused'})), return; end
            t = get_param(mdl,'SimulationTime');
            if t <= 0, return; end   % la t=0 iesirile nu sunt inca calculate (citire 0 -> contact fals)
            if ~isempty(buf.t) && t <= buf.t(end), return; end

            vF = [readSig(sig.v{1}) readSig(sig.v{2}) readSig(sig.v{3}) readSig(sig.v{4})];
            d  = [readSig(sig.d{1}) readSig(sig.d{2}) readSig(sig.d{3}) readSig(sig.d{4})];
            if any(isnan([vF d])), return; end
            dt = t - state.t;

            % --- liderul: pozitie / viteza (citite sau reconstruite) ---
            if sig.xL.ok
                xL = readSig(sig.xL);
            elseif sig.vL.ok
                xL = state.xL + 0.5*(readSig(sig.vL) + state.vL)*dt;
            else
                state.xF1 = state.xF1 + 0.5*(vF(1) + state.vF1)*dt;
                xL = state.xF1 + d(1);
            end
            if sig.vL.ok
                vL = readSig(sig.vL);
            elseif dt > 0
                vL = (xL - state.xL)/dt;
            else
                vL = state.vL;
            end
            state.t = t; state.xL = xL; state.vL = vL; state.vF1 = vF(1);

            % --- pozitii din distante: x_i = x_{i-1} - d_i (exact) ---
            x = zeros(1,5); x(1) = xL;
            for k = 1:4, x(k+1) = x(k) - d(k); end
            v = [vL vF];

            buf.t(end+1,1) = t; buf.v(end+1,:) = v; buf.x(end+1,:) = x; buf.d(end+1,:) = d;

            hit = d <= L_VEH;
            for k = find(hit & ~contactPrev), logMsg(sprintf('t=%.1f s  CONTACT %s',t,gapNames{k})); end
            contactPrev = hit;

            al = false(1,4);
            for k = 1:4
                if sig.al{k}.ok, al(k) = readSig(sig.al{k}) > 0; end
            end
            for k = find(al & ~alarmPrev), logMsg(sprintf('t=%.1f s  ALARMA detector F%d',t,k)); end
            for k = find(~al & alarmPrev), logMsg(sprintf('t=%.1f s  detector F%d: mesaj din nou plauzibil',t,k)); end
            alarmPrev = al; updateAlarmLamps(al);

            refresh(); updateTable(v,x,d); updateLamps(d); drawRoad(x,d);
            drawnow limitrate
        catch ME
            if ~strcmp(ME.message,lastErrMsg)
                lastErrMsg = ME.message; logMsg(['Tick: ' ME.message]);
            end
        end
    end

    function refresh()
        n = numel(buf.t); if n == 0, return; end
        tEnd = buf.t(n);
        if isfinite(winSec)
            t0 = max(0,tEnd - winSec); xl = [t0, max(winSec,tEnd)];
        else
            t0 = 0; xl = [0 max(1,tEnd)];
        end
        i0 = find(buf.t >= t0,1,'first'); if isempty(i0), i0 = 1; end
        idx = i0:max(1,ceil((n-i0+1)/1500)):n; if idx(end) ~= n, idx(end+1) = n; end
        tt = buf.t(idx);
        X = buf.x(idx,:); if relMode, X = X - X(:,1); end
        for i = 1:5
            set(hV(i),'XData',tt,'YData',buf.v(idx,i));
            set(hX(i),'XData',tt,'YData',X(:,i));
        end
        for i = 1:4, set(hD(i),'XData',tt,'YData',buf.d(idx,i)); end
        axV.XLim = xl; axX.XLim = xl; axD.XLim = xl;
        vis = find(visible);
        if ~isempty(vis)
            V = buf.v(idx,vis); axV.YLim = padLim(min(V(:)),max(V(:)),5);
            axX.YLim = padLim(min(min(X(:,vis))),max(max(X(:,vis))),20);
        end
        visG = find(visible(2:5));
        if ~isempty(visG)
            D = buf.d(idx,visG); axD.YLim = [0 max(20,1.15*max(D(:)))];
        end
    end

    function updateTable(v,x,d)
        C = cell(5,4);
        for i = 1:5
            C{i,1} = names{i}; C{i,2} = sprintf('%.2f',v(i)); C{i,3} = sprintf('%.1f',x(i));
            if i == 1, C{i,4} = '-'; else, C{i,4} = sprintf('%.1f',d(i-1)); end
        end
        tbl.Data = C;
    end

    function updateLamps(d)
        for k = 1:4
            if d(k) <= L_VEH,   lamp(k).Color = [0.85 0.10 0.10];
            elseif d(k) < D_DES + L_VEH, lamp(k).Color = [0.95 0.75 0.10];   % d e distanta intre pozitii
            else,                lamp(k).Color = [0.20 0.70 0.30];
            end
        end
    end

    function updateAlarmLamps(al)
        for k = 1:4
            if al(k), alarmLamp(k).Color = [0.85 0.10 0.10]; else, alarmLamp(k).Color = [0.75 0.75 0.75]; end
        end
    end

    function drawRoad(x,d)
        for i = 1:5
            rect(i).Position = [x(i)-L_VEH/2 -0.9 L_VEH 1.8];
            lab(i).Position  = [x(i) 2.0 0];
            rect(i).EdgeColor = [0.1 0.1 0.1]; rect(i).LineWidth = 1;
        end
        for k = find(d <= L_VEH)
            rect(k).EdgeColor = [0.9 0 0]; rect(k+1).EdgeColor = [0.9 0 0];
            rect(k).LineWidth = 3;         rect(k+1).LineWidth = 3;
        end
        lo = min(x) - 30; hi = max(x) + 30;
        if hi - lo < 90, c = (hi+lo)/2; lo = c - 45; hi = c + 45; end
        axRoad.XLim = [lo hi];
        placeSelection();
    end

    function refreshRoadOnly()
        placeSelection();
    end

    function placeSelection()
        p = rect(tgtDD.Value + 1).Position;
        selRect.Position = p + [-0.5 -0.35 1 0.7];
        if running && atk.type > 0 && atk.target == tgtDD.Value
            selRect.EdgeColor = [0.85 0.10 0.10];
        else
            selRect.EdgeColor = [0.95 0.60 0.10];
        end
    end

%% ================= Utilitare =================
    function clearData()
        buf = newBuf(); state = newState(x0); contactPrev = false(1,4); alarmPrev = false(1,4);
        updateAlarmLamps(alarmPrev);
        if ~isempty(evLines), delete(evLines(isvalid(evLines))); end
        evLines = gobjects(0);
        for i = 1:5, set(hV(i),'XData',NaN,'YData',NaN); set(hX(i),'XData',NaN,'YData',NaN); end
        for i = 1:4, set(hD(i),'XData',NaN,'YData',NaN); end
        axV.XLim = [0 winSec]; axX.XLim = [0 winSec]; axD.XLim = [0 winSec];
        axV.YLim = [-1 35]; axD.YLim = [0 40]; axX.YLim = [min(x0)-10 max(x0)+10];
        d0 = -diff(x0);
        updateTable(zeros(1,5),x0,d0); updateLamps(d0); drawRoad(x0,d0);
    end

    function markEvent(txt,col)
        t = 0; if ~isempty(buf.t), t = buf.t(end); end
        for ax = [axV axX axD]
            evLines(end+1) = xline(ax,t,'--',txt,'Color',col,'LineWidth',1.3, ...
                'LabelVerticalAlignment','top','FontSize',9); %#ok<AGROW>
        end
    end

    function logMsg(s)
        try
            logBox.Value = [logBox.Value; {s}];
            if numel(logBox.Value) > 80, logBox.Value = logBox.Value(end-79:end); end
            scroll(logBox,'bottom');
        catch
        end
    end

    function setButtons(mode)
        switch mode
            case 'idle'
                btnStart.Enable = 'on'; btnPause.Enable = 'off'; btnStop.Enable = 'off';
                btnPause.Text = 'Pauza'; tStepF.Enable = 'on';
            case 'running'
                btnStart.Enable = 'off'; btnPause.Enable = 'on'; btnStop.Enable = 'on';
                btnPause.Text = 'Pauza'; tStepF.Enable = 'off';
            case 'paused'
                btnStart.Enable = 'off'; btnPause.Enable = 'on'; btnStop.Enable = 'on';
                btnPause.Text = 'Continua'; tStepF.Enable = 'off';
        end
        setChip();
    end

    function showRow(lblH,fieldH,show,row)
        lblH.Visible = onoff(show); fieldH.Visible = onoff(show);
        if show, g2.RowHeight{row} = 28; else, g2.RowHeight{row} = 0; end
    end

    function stopSim()
        try
            if ~strcmp(get_param(mdl,'SimulationStatus'),'stopped')
                set_param(mdl,'SimulationCommand','stop');
                t0 = tic;
                while ~strcmp(get_param(mdl,'SimulationStatus'),'stopped') && toc(t0) < 10
                    pause(0.05);
                end
            end
        catch ME
            logMsg(['Stop esuat: ' ME.message]);
        end
    end

    function waitRunning()
        t0 = tic;
        while toc(t0) < 60
            s = get_param(mdl,'SimulationStatus');
            if any(strcmp(s,{'running','paused'})), return; end
            if strcmp(s,'stopped') && toc(t0) > 1
                error('Simularea s-a oprit inainte sa porneasca (vezi Diagnostic Viewer / Command Window).');
            end
            pause(0.05);
        end
        error('Timeout la pornirea simularii.');
    end

    function acquireSignals()
        sig.d = cell(1,4); sig.v = cell(1,4); sig.al = cell(1,4);
        for n = 1:4
            blk = sprintf('%s/Follower_%d',mdl,n);
            sig.al{n} = getRTO([blk '/CACC_Controller/CyberDetector'],2);
            if n == 1, dDef = 3; vDef = 4; else, dDef = 2; vDef = 3; end   % ca in versiunea veche
            sig.d{n} = getRTO(blk, findPort(blk,'(?i)interdist|distan|gap',dDef));
            % Portul Velocity vine dintr-un Bus Selector (virtual, fara RuntimeObject)
            % -> citim direct integratorul a->v din dinamica vehiculului.
            sig.v{n} = firstOk(getRTO([blk '/Vehicle_Dynamics/Int_a2v'],1), ...
                               getRTO(blk, findPort(blk,'(?i)veloc|viteza|speed',vDef)));
        end
        blkL = [mdl '/Leader_Vehicle'];
        dynL = [blkL '/Vehicle_Dynamics_Leader'];
        sig.xL = firstOk(getRTO([dynL '/Int_v2x'],1), getRTO(blkL, findPort(blkL,'(?i)pos|poz|^x(_|$)',0)));
        sig.vL = firstOk(getRTO([dynL '/Int_a2v'],1), getRTO(blkL, findPort(blkL,'(?i)vel|viteza|speed|^v(_|$)',0)));

        bad = {};
        for n = 1:4
            if ~sig.d{n}.ok, bad{end+1} = sprintf('distanta F%d',n); end %#ok<AGROW>
            if ~sig.v{n}.ok, bad{end+1} = sprintf('viteza F%d',n); end %#ok<AGROW>
        end
        if ~isempty(bad)
            error('Nu pot citi live: %s. Verifica porturile subsistemelor Follower_n.',strjoin(bad,', '));
        end
        logMsg(sprintf('Semnale OK. Lider: pozitie=%s, viteza=%s (altfel reconstruite). Detector: %s.', ...
            yesno(sig.xL.ok),yesno(sig.vL.ok),yesno(all(cellfun(@(s) s.ok,sig.al)))));
    end

    function closeApp(~,~)
        try, if ~isempty(tmr) && isvalid(tmr), stop(tmr); delete(tmr); end, catch, end
        try
            if ~strcmp(get_param(mdl,'SimulationStatus'),'stopped')
                set_param(mdl,'SimulationCommand','stop');
            end
        catch
        end
        delete(fig);
    end

    function removeUnrealBlocks()
        % Curata blocurile Unreal ramase din versiunea anterioara; salveaza doar daca a sters ceva.
        topBlocks = find_system(mdl,'SearchDepth',1,'Type','Block');
        removed = 0;
        for b = numel(topBlocks):-1:1
            blockName = get_param(topBlocks{b},'Name');
            if strcmp(blockName,'Unreal_Scene') || startsWith(blockName,'UE_')
                delete_block(topBlocks{b}); removed = removed + 1;
            end
        end
        if removed > 0, save_system(mdl); end
    end

end  % ===== sfarsit platoon_cyber_ui =====

%% ================= Functii locale =================
function s = onoff(tf)
if tf, s = 'on'; else, s = 'off'; end
end

function s = yesno(tf)
if tf, s = 'da'; else, s = 'nu'; end
end

function b = newBuf()
b = struct('t',zeros(0,1),'v',zeros(0,5),'x',zeros(0,5),'d',zeros(0,4));
end

function s = newState(x0)
s = struct('t',0,'xL',x0(1),'vL',0,'xF1',x0(2),'vF1',0);
end

function lim = padLim(lo,hi,minSpan)
if hi - lo < minSpan, c = (hi+lo)/2; lo = c - minSpan/2; hi = c + minSpan/2; end
p = 0.08*(hi-lo); lim = [lo-p hi+p];
end

function v = readSig(s)
try
    v = double(s.rto.OutputPort(s.port).Data); v = v(1);
catch
    v = NaN;
end
end

function p = findPort(blk,pattern,fallback)
% cauta portul de iesire al subsistemului dupa numele semnalului / al blocului Outport
p = fallback;
try
    ph = get_param(blk,'PortHandles');
    for k = 1:numel(ph.Outport)
        cand = {get_param(ph.Outport(k),'Name')};
        ob = find_system(blk,'SearchDepth',1,'BlockType','Outport','Port',num2str(k));
        if ~isempty(ob), cand{end+1} = get_param(ob{1},'Name'); end %#ok<AGROW>
        for c = 1:numel(cand)
            if ~isempty(cand{c}) && ~isempty(regexp(cand{c},pattern,'once'))
                p = k; return
            end
        end
    end
catch
end
end

function r = getRTO(blk,port)
% RuntimeObject al sursei reale (non-virtuale) a iesirii `port` din `blk`
r = struct('rto',[],'port',port,'ok',false);
if port < 1, return; end
try   % 1) direct pe bloc
    rt = get_param(blk,'RuntimeObject');
    if ~isempty(rt) && port <= rt.NumOutputPorts
        r.rto = rt; r.port = port; r.ok = true; return
    end
catch
end
try   % 2) urmareste semnalul prin subsisteme virtuale pana la un bloc real
    b = blk; p = port;
    for k = 1:12
        if ~strcmp(get_param(b,'BlockType'),'SubSystem'), break; end
        ob = find_system(b,'SearchDepth',1,'BlockType','Outport','Port',num2str(p));
        ph = get_param(ob{1},'PortHandles');
        ln = get_param(ph.Inport,'Line');
        sb = get_param(ln,'SrcBlockHandle'); sp = get_param(ln,'SrcPortHandle');
        p = get_param(sp,'PortNumber'); b = getfullname(sb);
    end
    rt = get_param(b,'RuntimeObject');
    if ~isempty(rt) && p <= rt.NumOutputPorts
        r.rto = rt; r.port = p; r.ok = true;
    end
catch
end
end

function r = firstOk(varargin)
% primul RuntimeObject valid dintre candidati (altfel ultimul, cu ok = false)
for k = 1:nargin
    r = varargin{k};
    if r.ok, return; end
end
end

function styleAx(ax,ttl)
title(ax,ttl,'FontSize',12);
try, ax.TitleHorizontalAlignment = 'left'; catch, end
grid(ax,'on'); box(ax,'on'); ax.NextPlot = 'add';
try, disableDefaultInteractivity(ax); ax.Toolbar.Visible = 'off'; catch, end
end
