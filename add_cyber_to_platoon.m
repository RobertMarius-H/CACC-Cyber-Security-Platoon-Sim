function add_cyber_to_platoon
% Integreaza injectarea DoS/FDI/Replay pe mesajul V2V complet al predecesorului
% (pozitie, viteza, acceleratie) si un detector de plauzibilitate.
% Ruleaza dupa init_platoon_params.m, din folderul modelului.
% Poate fi rulat de mai multe ori: un model fara atacuri sau cu o versiune
% anterioara a injectiei este adus la structura curenta; modelul se salveaza
% numai daca a fost modificat.
%
% Structura in fiecare CACC_Controller:
%   BusSel_Leader -> Cyber_RxMux [x;v;a] -> CyberInjector -> Cyber_RxDemux
%       -> Sum_Gap (x) | Sum_VelError (v) | FF_Filter (a)
%   CyberInjector -> CyberDetector -> Cyber_Residual_Log / Cyber_Alarm_Log
mdl = 'Platoon_Year1_CACC_fixed';
if ~bdIsLoaded(mdl), load_system(mdl); end
followers = {'Follower_1','Follower_2','Follower_3','Follower_4'};
x0Tx = {'x0_leader','x0_f(1)','x0_f(2)','x0_f(3)'};   % emitatorul V2V al fiecarui follower

for k = 1:numel(followers)
    c = [mdl '/' followers{k} '/CACC_Controller'];
    if ~hasBlock(c,'CyberDetector')
        removeCyber(c);
        buildCyber(c,k,x0Tx{k});
        fprintf('[OK] Atac DoS/FDI/Replay pe mesajul complet + detector pentru %s.\n',followers{k});
    end
    setScript([c '/CyberInjector'],injectorScript());
    setScript([c '/CyberDetector'],detectorScript());
end

% Mesajul V2V initial = starea initiala a emitatorului. Altfel primele 20 ms
% (Transport Delay) contin zerouri: distanta negativa la t=0, iar un DoS
% armat inainte de start ar ingheta un mesaj nul.
nets   = {'V2V_Network','V2V_Network1','V2V_Network2','V2V_Network3'};
fields = {'Position_m','Velocity_mps','Accel_mps2'};
for k = 1:numel(nets)
    init = {x0Tx{k},'v0','0'};
    for j = 1:numel(fields)
        setIfDiff([mdl '/' nets{k} '/TD_' fields{j}],'InitialOutput',init{j});
        setIfDiff([mdl '/' nets{k} '/UnitDelay_' fields{j}],'InitialCondition',init{j});
    end
end

% Logare pentru graficele UI: distanta si viteza fiecarui follower.
for k = 1:numel(followers)
    % To Workspace garanteaza ca UI-ul primeste seriile chiar daca MATLAB nu
    % include dataset-ul logsout in obiectul SimulationOutput.
    if k == 1, distancePort = 3; velocityPort = 4;
    else, distancePort = 2; velocityPort = 3; end
    logSpecs = { ...
        sprintf('UI_Distance_Log_F%d',k), sprintf('UI_Distance_F%d',k), distancePort; ...
        sprintf('UI_Velocity_Log_F%d',k), sprintf('UI_Velocity_F%d',k), velocityPort};
    for j = 1:size(logSpecs,1)
        blockName = logSpecs{j,1}; variableName = logSpecs{j,2}; port = logSpecs{j,3};
        if isempty(find_system(mdl,'SearchDepth',1,'Name',blockName))
            add_block('simulink/Sinks/To Workspace',[mdl '/' blockName], ...
                'VariableName',variableName,'SaveFormat','Timeseries', ...
                'Position',[2750 180+70*((k-1)*2+j-1) 2860 210+70*((k-1)*2+j-1)]);
            add_line(mdl,sprintf('%s/%d',followers{k},port), ...
                [blockName '/1'],'autorouting','on');
        end
    end
    signalSpecs = {'InterDistance',distancePort; 'Velocity',velocityPort};
    followerPorts = get_param([mdl '/' followers{k}],'PortHandles');
    for pair = 1:size(signalSpecs,1)
        nm = signalSpecs{pair,1};
        port = signalSpecs{pair,2};
        outport = followerPorts.Outport(port);
        sig = sprintf('%s_F%d',nm,k);
        % Logging-ul se configureaza pe portul sursa, nu pe handle-ul liniei.
        if ~strcmp(get_param(outport,'DataLogging'),'on') || ...
                ~strcmp(get_param(outport,'DataLoggingName'),sig)
            Simulink.sdi.markSignalForStreaming(outport,'on');
            set_param(outport,'DataLoggingNameMode','Custom','DataLoggingName',sig);
        end
    end
end
set_param(mdl,'SignalLogging','on','SignalLoggingName','logsout', ...
    'SignalLoggingSaveFormat','Dataset','ReturnWorkspaceOutputs','on');
if strcmp(get_param(mdl,'Dirty'),'on')
    save_system(mdl);
end
fprintf('Modelul %s este pregatit pentru simulare cyber si UI.\n',mdl);
end

function removeCyber(c)
% Sterge orice injectie cyber anterioara si legaturile receptorului V2V
% (BusSel_Leader -> consumatori), care sunt refacute de buildCyber.
blocks = find_system(c,'SearchDepth',1,'Regexp','on','Name','^Cyber');
for b = 1:numel(blocks)
    lh = get_param(blocks{b},'LineHandles');
    for h = [lh.Inport lh.Outport]
        if h ~= -1, try, delete_line(h); catch, end, end
    end
    delete_block(blocks{b});
end
ph = get_param([c '/BusSel_Leader'],'PortHandles');
for p = ph.Outport
    h = get_param(p,'Line');
    if h ~= -1, delete_line(h); end
end
% Segmente ramase fara sursa sau fara destinatie.
L = find_system(c,'SearchDepth',1,'FindAll','on','Type','line');
for h = L(:)'
    try
        if get_param(h,'SrcPortHandle') == -1 || all(get_param(h,'DstPortHandle') == -1)
            delete_line(h);
        end
    catch
    end
end
end

function buildCyber(c,k,x0Tx)
% x0Tx: expresia pozitiei initiale a emitatorului (pentru iesirea initiala Replay).
ports = fieldPorts([c '/BusSel_Leader']);

% Receptor: [x; v; a] -> injector -> consumatorii regulatorului.
add_block('simulink/Signal Routing/Mux',[c '/Cyber_RxMux'], ...
    'Inputs','3','Position',[320 140 325 220]);
for j = 1:3
    add_line(c,sprintf('BusSel_Leader/%d',ports(j)),sprintf('Cyber_RxMux/%d',j),'autorouting','on');
end
add_block('simulink/User-Defined Functions/MATLAB Function',[c '/CyberInjector'], ...
    'Position',[500 140 600 300]);
setScript([c '/CyberInjector'],injectorScript());
add_line(c,'Cyber_RxMux/1','CyberInjector/1','autorouting','on');

% Replay: Variable Time Delay cu intarzierea pe port (Constant reglabil live).
dly = [c '/Cyber_ReplayDelay'];
add_block('simulink/Continuous/Variable Transport Delay',dly, ...
    'Position',[360 230 440 270]);
try, set_param(dly,'VariableDelayType','Variable time delay'); catch, end
set_param(dly,'MaximumDelay','5','InitialOutput',sprintf('[%s; v0; 0]',x0Tx), ...
    'MaximumPoints','8192');
add_block('simulink/Sources/Constant',[c '/Cyber_DelayValue'], ...
    'Value','Cyber_ReplayDelay','Position',[270 245 330 265]);
add_line(c,'Cyber_RxMux/1','Cyber_ReplayDelay/1','autorouting','on');
add_line(c,'Cyber_DelayValue/1','Cyber_ReplayDelay/2','autorouting','on');
add_line(c,'Cyber_ReplayDelay/1','CyberInjector/2','autorouting','on');

% Parametrii atacului sunt cititi din workspace si pot fi configurati din UI.
names = {'Cyber_Mode','Cyber_Target','Cyber_Index','Cyber_Bias','Cyber_Field'};
vals  = {'Cyber_AttackType','Cyber_TargetVehicle',num2str(k), ...
         'Cyber_FDI_Bias','Cyber_FDI_Field'};
for j = 1:numel(names)
    yy = 300 + (j-1)*35;
    add_block('simulink/Sources/Constant',[c '/' names{j}], ...
        'Value',vals{j},'Position',[370 yy 450 yy+22]);
    add_line(c,[names{j} '/1'],sprintf('CyberInjector/%d',j+2),'autorouting','on');
end

add_block('simulink/Signal Routing/Demux',[c '/Cyber_RxDemux'], ...
    'Outputs','3','Position',[640 140 645 300]);
add_line(c,'CyberInjector/1','Cyber_RxDemux/1','autorouting','on');
add_line(c,'Cyber_RxDemux/1','Sum_Gap/1','autorouting','on');
add_line(c,'Cyber_RxDemux/2','Sum_VelError/1','autorouting','on');
add_line(c,'Cyber_RxDemux/3','FF_Filter/1','autorouting','on');

% Detector de plauzibilitate pe mesajul primit (dupa atac).
add_block('simulink/User-Defined Functions/MATLAB Function',[c '/CyberDetector'], ...
    'Position',[830 340 930 440]);
setScript([c '/CyberDetector'],detectorScript());
add_line(c,'CyberInjector/1','CyberDetector/1','autorouting','on');
add_block('simulink/Sources/Constant',[c '/Cyber_Threshold'], ...
    'Value','Cyber_ResidualThreshold','Position',[730 405 800 425]);
add_line(c,'Cyber_Threshold/1','CyberDetector/2','autorouting','on');

add_block('simulink/Sinks/To Workspace',[c '/Cyber_Residual_Log'], ...
    'VariableName',sprintf('Cyber_Residual_F%d',k), ...
    'SaveFormat','Timeseries','Position',[980 350 1080 380]);
add_line(c,'CyberDetector/1','Cyber_Residual_Log/1','autorouting','on');
add_block('simulink/Sinks/To Workspace',[c '/Cyber_Alarm_Log'], ...
    'VariableName',sprintf('Cyber_Alarm_F%d',k), ...
    'SaveFormat','Timeseries','Position',[980 430 1080 460]);
add_line(c,'CyberDetector/2','Cyber_Alarm_Log/1','autorouting','on');
end

function s = injectorScript()
s = strjoin({ ...
    'function y = cyber(u,uDelayed,mode,target,index,bias,field)'
    '% Atac pe mesajul V2V al predecesorului, u = [x; v; a] (m, m/s, m/s^2).'
    'persistent uLast'
    'if isempty(uLast), uLast = u; end'
    'y = u;'
    'active = target == index;'
    'isDoS = active && mode == 1;'
    'if isDoS'
    '    y = uLast; % DoS: mesaj blocat, receptorul pastreaza ultimul mesaj primit'
    'elseif active && mode == 2'
    '    k = min(max(round(field),1),3);'
    '    y(k) = u(k) + bias; % FDI: bias aditiv pe campul ales (1 x, 2 v, 3 a)'
    'elseif active && mode == 3'
    '    y = uDelayed; % Replay: mesaj vechi retransmis'
    'end'
    'if ~isDoS, uLast = u; end'
    'end'}',newline);
end

function s = detectorScript()
s = strjoin({ ...
    'function [residual,alarm] = detect(m,threshold)'
    '% Plauzibilitate intre campurile mesajului primit m = [x; v; a]:'
    '% d/dt(x) ~ v si d/dt(v) ~ a. Ambele parti trec prin acelasi filtru'
    '% 1/(Tf s + 1), initializat cu primul mesaj (fara salt la pornire).'
    '% Alarma doar daca reziduul depaseste pragul continuu 0.2 s (20 pasi de'
    '% 0.01 s), ca pierderile izolate de pachete sa nu declanseze alarma.'
    '% Primele 0.5 s detectorul doar se initializeaza (mesajul initial din'
    '% intarzierea V2V este constant, deci neplauzibil la viteza nenula).'
    'persistent prev f count n'
    'Ts = 0.01; Tf = 0.1; k = Ts/(Tf + Ts);'
    'if isempty(prev)'
    '    prev = m; f = [m(2); m(2); m(3); m(3)]; count = 0; n = 0;'
    'end'
    'n = n + 1;'
    'raw = [(m(1) - prev(1))/Ts; m(2); (m(2) - prev(2))/Ts; m(3)];'
    'f = f + k*(raw - f);'
    'prev = m;'
    'residual = [abs(f(1) - f(2)); abs(f(3) - f(4))];'
    'if n > 50 && max(residual) > threshold, count = count + 1; else, count = 0; end'
    'alarm = count >= 20;'
    'end'}',newline);
end

function setScript(blk,script)
chart = find(sfroot,'-isa','Stateflow.EMChart','Path',blk);
if ~strcmp(chart.Script,script), chart.Script = script; end
% Bloc discret la rata V2V (100 Hz): necesar pentru variabilele persistente,
% nepermise la timp continuu.
if ~strcmp(chart.ChartUpdate,'DISCRETE') || ~strcmp(chart.SampleTime,'0.01')
    chart.ChartUpdate = 'DISCRETE'; chart.SampleTime = '0.01';
end
end

function p = fieldPorts(busSel)
% Iesirile BusSel_Leader pentru [pozitie viteza acceleratie] (dupa numele semnalelor).
sigs = strsplit(get_param(busSel,'OutputSignals'),',');
pats = {'(?i)pos|poz','(?i)vel|speed|viteza','(?i)acc'};
p = [1 2 3];
for j = 1:3
    m = find(~cellfun(@isempty,regexp(sigs,pats{j},'once')),1);
    if ~isempty(m), p(j) = m; else, warning('Nu am gasit campul %d in %s.',j,busSel); end
end
end

function setIfDiff(blk,param,value)
if ~strcmp(get_param(blk,param),value), set_param(blk,param,value); end
end

function tf = hasBlock(parent,name)
tf = ~isempty(find_system(parent,'SearchDepth',1,'Name',name));
end
