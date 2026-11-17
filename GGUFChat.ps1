<#
.SYNOPSIS
    GGUF Chat - interface graphique PowerShell pour télécharger, charger et discuter
    avec un modèle GGUF en local (moteur : llama.cpp / llama-server).

.DESCRIPTION
    - Télécharge automatiquement llama.cpp (CPU, Vulkan ou CUDA 12) depuis GitHub
    - Télécharge un fichier .gguf depuis Internet (Hugging Face, lien direct...)
    - Lance / arrête le serveur llama-server en arrière-plan
    - Chat en streaming (réponse affichée en direct), prompt système, température, etc.

    Lancement :  powershell -STA -ExecutionPolicy Bypass -File C:\Users\t.langlois-teston\Documents\_TAFF\_Script\LLM\GGUFChat.ps1
    (ou double-clic sur Lancer.bat)
    
    ---  powershell -STA -ExecutionPolicy Bypass -File C:\Users\t.langlois-teston\Documents\_TAFF\_Script\LLM\GGUFChat.ps1
#>

# --- Relance en mode STA (obligatoire pour WinForms) -------------------------------------------
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $self = (Get-Process -Id $PID).Path
    Start-Process -FilePath $self -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- Configuration -----------------------------------------------------------------------------
$AppDir   = Join-Path $env:LOCALAPPDATA 'GGUFChat'
$BinDir   = Join-Path $AppDir 'bin'
$ModelDir = Join-Path $AppDir 'models'
$LogDir   = Join-Path $AppDir 'logs'
$Port     = 8089
$ApiBase  = "http://127.0.0.1:$Port"
$LogOut   = Join-Path $LogDir 'server.out.log'
$LogErr   = Join-Path $LogDir 'server.err.log'
foreach ($d in $AppDir, $BinDir, $ModelDir, $LogDir) { New-Item -ItemType Directory -Force -Path $d | Out-Null }

# --- État global -------------------------------------------------------------------------------
$script:proc        = $null
$script:serverReady = $false
$script:startedAt   = $null
$script:history     = New-Object System.Collections.Generic.List[object]
$script:chatBusy    = $false
$script:chatSync    = $null
$script:chatJob     = $null
$script:reply       = ''
$script:inThink     = $false
$script:dlBusy      = $false
$script:dlSync      = $null
$script:dlJob       = $null
$script:dlKind      = ''
$script:activeCtx   = 8192
$script:lastTotal   = 0
$script:statusExtra = ''
$script:metaCache   = @{}
$script:suspend     = $false

# =================================================================================================
#  Code exécuté en arrière-plan (runspaces) pour ne jamais figer l'interface
# =================================================================================================

# Fonction de téléchargement avec progression, redirections manuelles et token Hugging Face optionnel
$DownloadFn = @'
function Get-FileWithProgress {
    param($Url, $Dest, $Sync, $Token)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $resp = $null
    for ($i = 0; $i -lt 10; $i++) {
        $req = [Net.HttpWebRequest]::Create($Url)
        $req.UserAgent = 'GGUFChat/1.0'
        $req.AllowAutoRedirect = $false
        $req.Timeout = 30000
        $req.ReadWriteTimeout = 60000
        if ($Token -and ([Uri]$Url).Host -like '*huggingface.co') {
            $req.Headers['Authorization'] = 'Bearer ' + $Token
        }
        $resp = $req.GetResponse()
        $code = [int]$resp.StatusCode
        if ($code -ge 300 -and $code -lt 400) {
            $loc = $resp.Headers['Location']
            $resp.Close()
            $Url = ([Uri]::new([Uri]$Url, $loc)).AbsoluteUri
            $resp = $null
        } else { break }
    }
    if (-not $resp) { throw 'Trop de redirections.' }

    $total = $resp.ContentLength
    $in    = $resp.GetResponseStream()
    $part  = "$Dest.part"
    $out   = [IO.File]::Create($part)
    $ok    = $false
    try {
        $buf  = New-Object byte[] 262144
        $read = 0L
        $sw   = [Diagnostics.Stopwatch]::StartNew()
        $last = 0
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            if ($Sync.cancel) { throw 'Annulé' }
            $out.Write($buf, 0, $n)
            $read += $n
            if ($sw.ElapsedMilliseconds - $last -gt 250) {
                $last  = $sw.ElapsedMilliseconds
                $speed = $read / 1MB / [Math]::Max(0.001, $sw.Elapsed.TotalSeconds)
                if ($total -gt 0) {
                    $Sync.pct  = [int](100 * $read / $total)
                    $Sync.text = ('{0} : {1:N1} / {2:N1} Mo  ({3:N1} Mo/s)' -f $Sync.label, ($read / 1MB), ($total / 1MB), $speed)
                } else {
                    $Sync.text = ('{0} : {1:N1} Mo  ({2:N1} Mo/s)' -f $Sync.label, ($read / 1MB), $speed)
                }
            }
        }
        $ok = $true
    } finally {
        $out.Close(); $in.Close(); $resp.Close()
        if (-not $ok) { Remove-Item $part -Force -ErrorAction SilentlyContinue }
    }
    Move-Item -Path $part -Destination $Dest -Force
}
'@

# Téléchargement d'un modèle GGUF
$ModelScript = @'
param($Sync, $Url, $Dest, $Token)
try {
    $Sync.label = [IO.Path]::GetFileName($Dest)
    Get-FileWithProgress -Url $Url -Dest $Dest -Sync $Sync -Token $Token
    $Sync.pct = 100
    $Sync.result = $Dest
} catch {
    $m = $_.Exception.Message
    if ($m -match '401|403') { $m += "`nModèle à accès restreint ? Renseignez un token Hugging Face (et acceptez la licence du modèle sur le site)." }
    $Sync.error = $m
} finally { $Sync.done = $true }
'@

# Téléchargement + extraction de llama.cpp (dernière release GitHub)
$EngineScript = @'
param($Sync, $BinDir, $Backend)
try {
    $Sync.text = 'Recherche de la dernière version de llama.cpp...'
    $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/ggml-org/llama.cpp/releases/latest' -Headers @{ 'User-Agent' = 'GGUFChat' }
    $groups = switch ($Backend) {
        'Vulkan'  { @('^llama-.*-bin-win-vulkan-x64\.zip$') }
        'CUDA 12' { @('^llama-.*-bin-win-cuda-12[.\d]*-x64\.zip$', '^cudart-llama-bin-win-cuda-12[.\d]*-x64\.zip$') }
        default   { @('^llama-.*-bin-win-cpu-x64\.zip$ ^llama-.*-bin-win-avx2-x64\.zip$') }
    }
    foreach ($g in @($groups)) {
        $asset = $null
        foreach ($p in ($g -split ' ')) {
            $asset = $rel.assets | Where-Object { $_.name -match $p } | Select-Object -First 1
            if ($asset) { break }
        }
        if (-not $asset) { throw "Aucun binaire Windows ($Backend) trouvé dans la release $($rel.tag_name)." }
        $zip = Join-Path $env:TEMP $asset.name
        $Sync.label = $asset.name
        $Sync.pct = 0
        Get-FileWithProgress -Url $asset.browser_download_url -Dest $zip -Sync $Sync -Token $null
        $Sync.pct = 100
        $Sync.text = 'Extraction de ' + $asset.name + '...'
        Expand-Archive -Path $zip -DestinationPath $BinDir -Force
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
    }
    $exe = Get-ChildItem -Path $BinDir -Recurse -Filter 'llama-server.exe' | Select-Object -First 1
    if (-not $exe) { throw 'llama-server.exe introuvable après extraction.' }
    $Sync.result = $exe.FullName
} catch {
    $Sync.error = $_.Exception.Message
} finally { $Sync.done = $true }
'@

# Requête de chat en streaming (API compatible OpenAI de llama-server)
$ChatScript = @'
param($Sync, $Url, $Json)
try {
    $req = [Net.HttpWebRequest]::Create($Url)
    $Sync.req = $req
    $req.Method = 'POST'
    $req.ContentType = 'application/json; charset=utf-8'
    $req.Timeout = 3600000
    $req.ReadWriteTimeout = 3600000
    $req.KeepAlive = $false
    $bytes = [Text.Encoding]::UTF8.GetBytes($Json)
    $req.ContentLength = $bytes.Length
    $st = $req.GetRequestStream(); $st.Write($bytes, 0, $bytes.Length); $st.Close()
    $resp = $req.GetResponse()
    $sr = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
    while (-not $Sync.cancel) {
        $line = $sr.ReadLine()
        if ($null -eq $line) { break }
        if (-not $line.StartsWith('data:')) { continue }
        $d = $line.Substring(5).Trim()
        if ($d -eq '[DONE]') { break }
        if (-not $d) { continue }
        $o = $d | ConvertFrom-Json
        if ($o.error) { $Sync.queue.Enqueue('E' + $o.error.message); break }
        if ($o.usage -and $o.usage.prompt_tokens) {
            $tps = ''
            if ($o.timings -and $o.timings.predicted_per_second) { $tps = '{0:N1}' -f [double]$o.timings.predicted_per_second }
            $Sync.queue.Enqueue('U' + $o.usage.prompt_tokens + ';' + $o.usage.completion_tokens + ';' + $tps)
        }
        if ($o.choices -and $o.choices.Count -gt 0) {
            $delta = $o.choices[0].delta
            if ($delta.reasoning_content) { $Sync.queue.Enqueue('R' + $delta.reasoning_content) }
            if ($delta.content)           { $Sync.queue.Enqueue('C' + $delta.content) }
        }
    }
    $sr.Close(); $resp.Close()
} catch {
    if (-not $Sync.cancel) {
        $msg = $_.Exception.Message
        if ($_.Exception.Response) {
            try { $msg += ' ' + (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() } catch {}
        }
        $Sync.queue.Enqueue('E' + $msg)
    }
} finally { $Sync.done = $true }
'@

function Start-Bg {
    param([string]$Script, [hashtable]$Params)
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($Script)
    foreach ($k in $Params.Keys) { [void]$ps.AddParameter($k, $Params[$k]) }
    @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke() }
}

function Stop-Bg {
    param($Job)
    if (-not $Job) { return }
    try { $Job.PS.Dispose() } catch {}
    try { $Job.RS.Close(); $Job.RS.Dispose() } catch {}
}

# =================================================================================================
#  Interface
# =================================================================================================
function New-Ctl {
    param([string]$Type, [int]$X = 0, [int]$Y = 0, [int]$W = 0, [int]$H = 0, $Props = $null, $Parent = $null)
    $c = New-Object ("System.Windows.Forms.$Type")
    $c.Location = New-Object System.Drawing.Point($X, $Y)
    if ($W -gt 0) { $c.Size = New-Object System.Drawing.Size($W, $H) }
    if ($Props) { foreach ($k in $Props.Keys) { $c.$k = $Props[$k] } }
    if ($Parent) { $Parent.Controls.Add($c) }
    $c
}

function Show-Msg {
    param([string]$Text, [string]$Icon = 'Information')
    [void][System.Windows.Forms.MessageBox]::Show($form, $Text, 'GGUF Chat', 'OK', $Icon)
}

$AR  = 'Top, Right'
$ALR = 'Top, Left, Right'

$form = New-Ctl 'Form' 0 0 1000 800 @{
    Text = 'GGUF Chat - discuter avec un modèle local'; StartPosition = 'CenterScreen'
    MinimumSize = New-Object System.Drawing.Size(860, 640)
    Font = New-Object System.Drawing.Font('Segoe UI', 9)
}

$layout = New-Ctl 'TableLayoutPanel' 0 0 0 0 @{ Dock = 'Fill'; ColumnCount = 1; RowCount = 3 } $form
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 318)))
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 100)))

$pTop = New-Ctl 'Panel' 0 0 0 0 @{ Dock = 'Fill' }
$layout.Controls.Add($pTop, 0, 0)

# Ligne 1 : moteur
[void](New-Ctl 'Label' 10 14 0 0 @{ Text = 'Moteur :'; AutoSize = $true } $pTop)
$tbServer      = New-Ctl 'TextBox'  80  10 520 24 @{ Anchor = $ALR } $pTop
$btnSrvBrowse  = New-Ctl 'Button'  605   9  40 26 @{ Text = '...'; Anchor = $AR } $pTop
$cbBackend     = New-Ctl 'ComboBox' 650 10 100 24 @{ DropDownStyle = 'DropDownList'; Anchor = $AR } $pTop
[void]$cbBackend.Items.AddRange(@('CPU', 'Vulkan', 'CUDA 12')); $cbBackend.SelectedIndex = 0
$btnDlEngine   = New-Ctl 'Button'  755   9 205 26 @{ Text = 'Télécharger llama.cpp'; Anchor = $AR } $pTop

# Ligne 2 : modèle local
[void](New-Ctl 'Label' 10 48 0 0 @{ Text = 'Modèle :'; AutoSize = $true } $pTop)
$cbModel        = New-Ctl 'ComboBox' 80 44 520 24 @{ DropDownStyle = 'DropDownList'; Anchor = $ALR } $pTop
$btnMdlBrowse   = New-Ctl 'Button'  605 43  40 26 @{ Text = '...'; Anchor = $AR } $pTop
$btnRefresh     = New-Ctl 'Button'  650 43 100 26 @{ Text = 'Actualiser'; Anchor = $AR } $pTop
$btnOpenDir     = New-Ctl 'Button'  755 43 205 26 @{ Text = 'Ouvrir le dossier des modèles'; Anchor = $AR } $pTop

# Ligne 3 : téléchargement d'un GGUF
[void](New-Ctl 'Label' 10 82 0 0 @{ Text = 'URL GGUF :'; AutoSize = $true } $pTop)
$tbUrl   = New-Ctl 'TextBox' 80 78 520 24 @{ Anchor = $ALR; Text = 'https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf' } $pTop
[void](New-Ctl 'Label' 605 82 0 0 @{ Text = 'Token HF :'; AutoSize = $true; Anchor = $AR } $pTop)
$tbToken = New-Ctl 'TextBox' 675 78 75 24 @{ Anchor = $AR; UseSystemPasswordChar = $true } $pTop
$btnDlModel = New-Ctl 'Button' 755 77 205 26 @{ Text = 'Télécharger le modèle'; Anchor = $AR } $pTop

# Progression
$pb          = New-Ctl 'ProgressBar' 10 112 850 18 @{ Anchor = $ALR; Minimum = 0; Maximum = 100 } $pTop
$btnCancelDl = New-Ctl 'Button' 865 108 95 26 @{ Text = 'Annuler'; Anchor = $AR; Enabled = $false } $pTop
$lblDl       = New-Ctl 'Label' 10 136 950 18 @{ Text = 'Prêt.'; Anchor = $ALR } $pTop

# Paramètres : profil, contexte, GPU, cache KV
[void](New-Ctl 'Label' 10 166 0 0 @{ Text = 'Profil :'; AutoSize = $true } $pTop)
$cbProfile = New-Ctl 'ComboBox' 60 162 170 24 @{ DropDownStyle = 'DropDownList' } $pTop
[void]$cbProfile.Items.AddRange(@('Personnalisé', 'Équilibré (8k)', 'Long (16k)', 'Très long (32k)', 'Ultra (64k)', 'Extrême (128k)'))
$cbProfile.SelectedIndex = 2
[void](New-Ctl 'Label' 245 166 0 0 @{ Text = 'Contexte :'; AutoSize = $true } $pTop)
$nudCtx  = New-Ctl 'NumericUpDown' 310 162 80 24 ([ordered]@{ Minimum = 512; Maximum = 1048576; Increment = 1024; Value = 16384 }) $pTop
[void](New-Ctl 'Label' 405 166 0 0 @{ Text = 'Couches GPU :'; AutoSize = $true } $pTop)
$nudNgl  = New-Ctl 'NumericUpDown' 495 162 55 24 ([ordered]@{ Minimum = 0; Maximum = 999; Value = 0 }) $pTop
[void](New-Ctl 'Label' 565 166 0 0 @{ Text = 'VRAM Go :'; AutoSize = $true } $pTop)
$nudVram = New-Ctl 'NumericUpDown' 635 162 50 24 ([ordered]@{ DecimalPlaces = 1; Increment = [decimal]0.5; Minimum = 0; Maximum = 64; Value = [decimal]3.5 }) $pTop
[void](New-Ctl 'Label' 700 166 0 0 @{ Text = 'Temp. :'; AutoSize = $true } $pTop)
$nudTemp = New-Ctl 'NumericUpDown' 748 162 50 24 ([ordered]@{ DecimalPlaces = 1; Increment = [decimal]0.1; Minimum = 0; Maximum = 2; Value = [decimal]0.7 }) $pTop
[void](New-Ctl 'Label' 805 166 0 0 @{ Text = 'Max tokens :'; AutoSize = $true } $pTop)
$nudMax  = New-Ctl 'NumericUpDown' 880 162 70 24 ([ordered]@{ Minimum = -1; Maximum = 32768; Increment = 128; Value = 1024 }) $pTop

[void](New-Ctl 'Label' 10 198 0 0 @{ Text = 'Cache KV :'; AutoSize = $true } $pTop)
$cbKv = New-Ctl 'ComboBox' 75 194 65 24 @{ DropDownStyle = 'DropDownList' } $pTop
[void]$cbKv.Items.AddRange(@('f16', 'q8_0', 'q4_0')); $cbKv.SelectedItem = 'q8_0'
$chkFa   = New-Ctl 'CheckBox' 150 195 125 24 @{ Text = 'Flash Attention'; Checked = $true } $pTop
$chkNkvo = New-Ctl 'CheckBox' 280 195 195 24 @{ Text = 'Cache KV en RAM (-nkvo)'; Checked = $false } $pTop
[void](New-Ctl 'Label' 485 198 0 0 @{ Text = 'Threads :'; AutoSize = $true } $pTop)
$cpuCores = 4
try { $cpuCores = [int](Get-CimInstance Win32_Processor | Measure-Object NumberOfCores -Sum).Sum } catch {}
$logical = [Math]::Max(1, [Environment]::ProcessorCount)
$nudThreads = New-Ctl 'NumericUpDown' 545 194 50 24 ([ordered]@{
    Minimum = 1; Maximum = $logical; Value = [Math]::Max(1, [Math]::Min($logical, [Math]::Max(4, $cpuCores - 2))) }) $pTop

$btnStart = New-Ctl 'Button' 640 192 150 28 @{ Text = 'Démarrer le serveur'; Anchor = $AR } $pTop
$btnStop  = New-Ctl 'Button' 795 192  80 28 @{ Text = 'Arrêter'; Anchor = $AR; Enabled = $false } $pTop
$btnLog   = New-Ctl 'Button' 880 192  80 28 @{ Text = 'Journal'; Anchor = $AR } $pTop

$lblEst  = New-Ctl 'Label' 10 230 780 20 @{ Text = 'Estimation mémoire : sélectionnez un modèle.'; Anchor = $ALR; AutoSize = $false; ForeColor = [System.Drawing.Color]::DimGray } $pTop
$btnAuto = New-Ctl 'Button' 795 226 165 26 @{ Text = 'Auto-régler GPU'; Anchor = $AR } $pTop

[void](New-Ctl 'Label' 10 266 0 0 @{ Text = 'Système :'; AutoSize = $true } $pTop)
$tbSystem = New-Ctl 'TextBox' 80 262 880 24 @{ Anchor = $ALR; Text = 'Tu es un assistant serviable et concis. Réponds en français sauf demande contraire.' } $pTop

$lblSrv = New-Ctl 'Label' 10 292 950 20 @{
    Text = 'Serveur : arrêté'; Anchor = $ALR; ForeColor = [System.Drawing.Color]::DimGray
    Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
} $pTop

# Zone de conversation
$chatBox = New-Ctl 'RichTextBox' 0 0 0 0 @{
    Dock = 'Fill'; ReadOnly = $true; BackColor = [System.Drawing.Color]::White
    Font = New-Object System.Drawing.Font('Segoe UI', 10.5); BorderStyle = 'FixedSingle'; DetectUrls = $true
}
$layout.Controls.Add($chatBox, 0, 1)

# Zone de saisie
$tIn = New-Ctl 'TableLayoutPanel' 0 0 0 0 @{ Dock = 'Fill'; ColumnCount = 2; RowCount = 1 }
[void]$tIn.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$tIn.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 135)))
$layout.Controls.Add($tIn, 0, 2)

$tbInput = New-Ctl 'TextBox' 0 0 0 0 @{
    Dock = 'Fill'; Multiline = $true; AcceptsReturn = $true; ScrollBars = 'Vertical'
    Font = New-Object System.Drawing.Font('Segoe UI', 10.5)
}
$tIn.Controls.Add($tbInput, 0, 0)
$pBtn = New-Ctl 'Panel' 0 0 0 0 @{ Dock = 'Fill' }
$tIn.Controls.Add($pBtn, 1, 0)
$btnSend    = New-Ctl 'Button' 5  2 120 30 @{ Text = 'Envoyer'; Enabled = $false } $pBtn
$btnStopGen = New-Ctl 'Button' 5 35 120 30 @{ Text = 'Stop génération'; Enabled = $false } $pBtn
$btnClear   = New-Ctl 'Button' 5 68 120 28 @{ Text = 'Effacer' } $pBtn

$tip = New-Object System.Windows.Forms.ToolTip
$tip.SetToolTip($tbUrl,    'Lien direct vers un .gguf (les liens Hugging Face /blob/ sont convertis automatiquement).')
$tip.SetToolTip($tbToken,  'Optionnel : token Hugging Face pour les modèles à accès restreint (Llama, Gemma...).')
$tip.SetToolTip($nudNgl,   '0 = tout sur le CPU. Avec une carte GPU (Vulkan/CUDA), mettez 99 pour tout décharger.')
$tip.SetToolTip($nudMax,   '-1 = illimité.')
$tip.SetToolTip($btnSend,  'Entrée = envoyer, Maj+Entrée = nouvelle ligne.')
$tip.SetToolTip($chkNkvo,    'Garde le cache KV en RAM : libère la VRAM pour plus de couches GPU. Conseillé pour les très grands contextes.')
$tip.SetToolTip($chkFa,      'Réduit fortement la mémoire de calcul. Obligatoire pour quantifier le cache KV.')
$tip.SetToolTip($cbKv,       'f16 = qualité maximale ; q8_0 = 2x moins de mémoire, perte minime ; q4_0 = 3,5x moins, perte visible.')
$tip.SetToolTip($nudThreads, 'Cœurs utilisés pour le calcul CPU. Restez <= au nombre de cœurs physiques (trop de threads ralentit).')
$tip.SetToolTip($nudVram,    'VRAM dédiée réellement utilisable (gardez ~0,5 Go pour Windows). La mémoire partagée est trop lente : ne pas compter dessus.')
$tip.SetToolTip($btnAuto,    'Calcule le nombre de couches GPU qui tiennent dans la VRAM indiquée.')

# --- Polices / affichage du chat ---------------------------------------------------------------
$Fonts = @{
    Regular = New-Object System.Drawing.Font('Segoe UI', 10.5)
    Bold    = New-Object System.Drawing.Font('Segoe UI', 10.5, [System.Drawing.FontStyle]::Bold)
    Italic  = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Italic)
}
function Add-Chat {
    param([string]$Text, $Color = [System.Drawing.Color]::Black, [string]$Style = 'Regular')
    $chatBox.SelectionStart  = $chatBox.TextLength
    $chatBox.SelectionLength = 0
    $chatBox.SelectionColor  = $Color
    $chatBox.SelectionFont   = $Fonts[$Style]
    $chatBox.AppendText($Text)
    $chatBox.SelectionStart  = $chatBox.TextLength
    $chatBox.ScrollToCaret()
}

# --- Gestion de l'état de l'interface ----------------------------------------------------------
function Set-UiState {
    param([string]$State)
    switch ($State) {
        'stopped' {
            $lblSrv.Text = 'Serveur : arrêté'; $lblSrv.ForeColor = [System.Drawing.Color]::DimGray
            $btnStart.Enabled = -not $script:dlBusy; $btnStop.Enabled = $false; $btnSend.Enabled = $false
        }
        'loading' {
            $lblSrv.ForeColor = [System.Drawing.Color]::DarkOrange
            $btnStart.Enabled = $false; $btnStop.Enabled = $true; $btnSend.Enabled = $false
        }
        'ready' {
            Update-ReadyLabel
            $lblSrv.ForeColor = [System.Drawing.Color]::SeaGreen
            $btnStart.Enabled = $false; $btnStop.Enabled = $true; $btnSend.Enabled = (-not $script:chatBusy)
        }
    }
}

function Update-ModelList {
    $cur = $cbModel.Text
    $cbModel.Items.Clear()
    Get-ChildItem -Path $ModelDir -Filter '*.gguf' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | ForEach-Object { [void]$cbModel.Items.Add($_.FullName) }
    if ($cur -and (Test-Path $cur)) {
        if (-not $cbModel.Items.Contains($cur)) { [void]$cbModel.Items.Add($cur) }
        $cbModel.SelectedItem = $cur
    } elseif ($cbModel.Items.Count -gt 0) { $cbModel.SelectedIndex = 0 }
}

# --- Estimation mémoire (lecture des métadonnées GGUF) ----------------------------------------
Add-Type -AssemblyName Microsoft.VisualBasic
if (-not ('GgufMeta' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

public static class GgufMeta
{
    public static string Arch;
    static string[] Wanted = new string[] { "block_count", "embedding_length", "context_length",
        "attention.head_count", "attention.head_count_kv", "attention.key_length", "attention.value_length" };

    static string ReadStr(BinaryReader br)
    {
        ulong n = br.ReadUInt64();
        return Encoding.UTF8.GetString(br.ReadBytes((int)n));
    }

    static int SizeOf(uint t)
    {
        switch (t)
        {
            case 0: case 1: case 7: return 1;
            case 2: case 3: return 2;
            case 4: case 5: case 6: return 4;
            case 10: case 11: case 12: return 8;
        }
        throw new Exception("Type GGUF inconnu : " + t);
    }

    static double ReadNum(BinaryReader br, uint t)
    {
        switch (t)
        {
            case 0: return br.ReadByte();
            case 1: return br.ReadSByte();
            case 2: return br.ReadUInt16();
            case 3: return br.ReadInt16();
            case 4: return br.ReadUInt32();
            case 5: return br.ReadInt32();
            case 6: return br.ReadSingle();
            case 7: return br.ReadByte();
            case 10: return br.ReadUInt64();
            case 11: return br.ReadInt64();
            case 12: return br.ReadDouble();
        }
        throw new Exception("Type GGUF inconnu : " + t);
    }

    static void SkipStrings(BinaryReader br, ulong n)
    {
        for (ulong k = 0; k < n; k++)
        {
            ulong l = br.ReadUInt64();
            br.BaseStream.Seek((long)l, SeekOrigin.Current);
        }
    }

    static void Skip(BinaryReader br, uint t)
    {
        Stream s = br.BaseStream;
        if (t == 8)
        {
            ulong l = br.ReadUInt64();
            s.Seek((long)l, SeekOrigin.Current);
        }
        else if (t == 9)
        {
            uint et = br.ReadUInt32();
            ulong n = br.ReadUInt64();
            if (et == 8) SkipStrings(br, n);
            else s.Seek((long)n * SizeOf(et), SeekOrigin.Current);
        }
        else s.Seek(SizeOf(t), SeekOrigin.Current);
    }

    public static Dictionary<string, double> Read(string path)
    {
        Arch = null;
        Dictionary<string, double> res = new Dictionary<string, double>();
        using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
        using (BinaryReader br = new BinaryReader(fs))
        {
            if (Encoding.ASCII.GetString(br.ReadBytes(4)) != "GGUF") throw new Exception("Fichier GGUF invalide.");
            br.ReadUInt32();
            br.ReadUInt64();
            ulong kv = br.ReadUInt64();
            for (ulong i = 0; i < kv; i++)
            {
                string key = ReadStr(br);
                uint t = br.ReadUInt32();
                if (key == "general.architecture" && t == 8) { Arch = ReadStr(br); continue; }
                string suffix = null;
                if (Arch != null && key.StartsWith(Arch + "."))
                {
                    suffix = key.Substring(Arch.Length + 1);
                    if (Array.IndexOf(Wanted, suffix) < 0) suffix = null;
                }
                if (suffix == null) { Skip(br, t); continue; }
                if (t == 8) { Skip(br, t); continue; }
                if (t == 9)
                {
                    uint et = br.ReadUInt32();
                    ulong n = br.ReadUInt64();
                    if (et == 8) { SkipStrings(br, n); continue; }
                    if (n == 0 || n > 8192) { br.BaseStream.Seek((long)n * SizeOf(et), SeekOrigin.Current); continue; }
                    double sum = 0;
                    for (ulong k = 0; k < n; k++) sum += ReadNum(br, et);
                    res[suffix] = sum / n;
                }
                else res[suffix] = ReadNum(br, t);
            }
        }
        return res;
    }
}
'@
}

function Get-ModelMeta {
    param([string]$Path)
    if ($script:metaCache.ContainsKey($Path)) { return $script:metaCache[$Path] }
    $v = [GgufMeta]::Read($Path)
    $arch = [GgufMeta]::Arch
    $size = (Get-Item -LiteralPath $Path).Length
    if ($Path -match '^(.*)-\d{5}-of-\d{5}\.gguf$') {
        $prefix = Split-Path $Matches[1] -Leaf
        $size = (Get-ChildItem -LiteralPath (Split-Path $Path) -Filter ($prefix + '-*-of-*.gguf') | Measure-Object Length -Sum).Sum
    }
    $m = @{ v = $v; size = [double]$size; arch = $arch }
    $script:metaCache[$Path] = $m
    $m
}

function Get-Estimate {
    param([string]$Path, [int]$Ctx, [string]$KvType, [int]$Ngl, [bool]$Nkvo)
    $m = Get-ModelMeta $Path
    $v = $m.v
    if (-not ($v.ContainsKey('block_count') -and $v.ContainsKey('embedding_length') -and $v.ContainsKey('attention.head_count'))) { return $null }
    $L = [double]$v['block_count']
    $E = [double]$v['embedding_length']
    $H = [double]$v['attention.head_count']
    $HK = if ($v.ContainsKey('attention.head_count_kv')) { [double]$v['attention.head_count_kv'] } else { $H }
    $kl = if ($v.ContainsKey('attention.key_length'))   { [double]$v['attention.key_length'] }   else { $E / $H }
    $vl = if ($v.ContainsKey('attention.value_length')) { [double]$v['attention.value_length'] } else { $E / $H }
    $bpe = switch ($KvType) { 'q8_0' { 34 / 32 } 'q4_0' { 18 / 32 } default { 2 } }
    $kv = $Ctx * $L * $HK * ($kl + $vl) * $bpe
    $size = $m.size
    $gpuModel = $size * [Math]::Min(1.0, $Ngl / ($L + 1))
    $gpuKv = if ($Nkvo) { 0 } else { $kv * [Math]::Min(1.0, $Ngl / $L) }
    $gpu = if ($Ngl -gt 0) { $gpuModel + $gpuKv + 0.4GB } else { 0 }
    $ram = ($size - $gpuModel) + ($kv - $gpuKv) + 0.6GB
    $train = if ($v.ContainsKey('context_length')) { [double]$v['context_length'] } else { 0 }
    @{ L = $L; Size = $size; Kv = $kv; Gpu = $gpu; Ram = $ram; TrainCtx = $train }
}

function Update-Estimate {
    if ($script:suspend) { return }
    $path = $cbModel.Text
    if (-not $path -or -not (Test-Path -LiteralPath $path)) {
        $lblEst.Text = 'Estimation mémoire : sélectionnez un modèle.'
        $lblEst.ForeColor = [System.Drawing.Color]::DimGray
        return
    }
    try {
        $kvType = [string]$cbKv.SelectedItem
        $ctx = [int]$nudCtx.Value
        $e = Get-Estimate -Path $path -Ctx $ctx -KvType $kvType -Ngl ([int]$nudNgl.Value) -Nkvo $chkNkvo.Checked
        if (-not $e) {
            $lblEst.Text = 'Estimation indisponible (métadonnées du modèle non reconnues).'
            $lblEst.ForeColor = [System.Drawing.Color]::DimGray
            return
        }
        $free = [double](New-Object Microsoft.VisualBasic.Devices.ComputerInfo).AvailablePhysicalMemory
        $vramMax = [double]$nudVram.Value * 1GB
        $txt = 'Estimation : modèle {0:N1} Go + cache KV {1:N1} Go ({2}, {3:N0} tokens)  |  RAM ≈ {4:N1} Go (libre {5:N1} Go)' -f `
            ($e.Size / 1GB), ($e.Kv / 1GB), $kvType, $ctx, ($e.Ram / 1GB), ($free / 1GB)
        if ($nudNgl.Value -gt 0) { $txt += ('  |  VRAM ≈ {0:N1} / {1:N1} Go' -f ($e.Gpu / 1GB), ($vramMax / 1GB)) }
        if ($e.TrainCtx -gt 0 -and $ctx -gt $e.TrainCtx) { $txt += ('  |  ⚠ dépasse le contexte d''entraînement ({0:N0})' -f $e.TrainCtx) }
        $lblEst.Text = $txt
        if ($e.Ram -gt $free * 0.95 -or $e.Gpu -gt $vramMax * 1.05) { $lblEst.ForeColor = [System.Drawing.Color]::Firebrick }
        elseif ($e.Ram -gt $free * 0.8 -or $e.Gpu -gt $vramMax) { $lblEst.ForeColor = [System.Drawing.Color]::DarkOrange }
        else { $lblEst.ForeColor = [System.Drawing.Color]::SeaGreen }
    } catch {
        $lblEst.Text = 'Estimation indisponible : ' + $_.Exception.Message
        $lblEst.ForeColor = [System.Drawing.Color]::DimGray
    }
}

function Set-AutoGpu {
    $path = $cbModel.Text
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { Show-Msg 'Sélectionnez d''abord un modèle.' 'Warning'; return }
    try {
        $e = Get-Estimate -Path $path -Ctx ([int]$nudCtx.Value) -KvType ([string]$cbKv.SelectedItem) -Ngl 0 -Nkvo $chkNkvo.Checked
        if (-not $e) { Show-Msg 'Métadonnées du modèle non reconnues : réglez les couches GPU à la main.' 'Warning'; return }
        $budget = [double]$nudVram.Value * 1GB - 0.45GB
        $perLayer = $e.Size / ($e.L + 1)
        if (-not $chkNkvo.Checked) { $perLayer += $e.Kv / $e.L }
        $n = [int][Math]::Floor($budget / $perLayer)
        $n = [Math]::Max(0, [Math]::Min([int]$e.L + 1, $n))
        $nudNgl.Value = $n
        Update-Estimate
    } catch { Show-Msg ('Calcul impossible : ' + $_.Exception.Message) 'Warning' }
}

function Update-ReadyLabel {
    $t = "Serveur : prêt - $ApiBase"
    if ($script:statusExtra) { $t += '   |   ' + $script:statusExtra }
    $lblSrv.Text = $t
}

# --- Serveur llama.cpp -------------------------------------------------------------------------
function Stop-Server {
    $srvTimer.Stop()
    if ($script:chatBusy) { Stop-Generation }
    if ($script:proc -and -not $script:proc.HasExited) {
        try { $script:proc.Kill() } catch {}
        [void]$script:proc.WaitForExit(3000)
    }
    $script:proc = $null
    $script:serverReady = $false
    Set-UiState 'stopped'
}

function Start-Server {
    $exe   = $tbServer.Text.Trim()
    $model = $cbModel.Text
    if (-not (Test-Path $exe)) { Show-Msg "Indiquez ou téléchargez d'abord llama-server.exe (bouton « Télécharger llama.cpp »)." 'Warning'; return }
    if (-not $model -or -not (Test-Path $model)) { Show-Msg "Sélectionnez ou téléchargez d'abord un modèle .gguf." 'Warning'; return }
    Stop-Server
    $ctx = [int]$nudCtx.Value
    $kv  = [string]$cbKv.SelectedItem
    if ($kv -ne 'f16' -and -not $chkFa.Checked) { $chkFa.Checked = $true }   # requis pour quantifier le cache KV
    $a = @('-m', "`"$model`"", '--host', '127.0.0.1', '--port', $Port, '-c', $ctx,
           '-ngl', [int]$nudNgl.Value, '-np', 1, '-t', [int]$nudThreads.Value, '--jinja')
    if ($chkFa.Checked)   { $a += @('--flash-attn', 'on') }
    if ($kv -ne 'f16')    { $a += @('-ctk', $kv, '-ctv', $kv) }
    if ($chkNkvo.Checked) { $a += '--no-kv-offload' }
    $argList = $a -join ' '
    $script:activeCtx = $ctx; $script:lastTotal = 0; $script:statusExtra = ''
    try {
        $script:proc = Start-Process -FilePath $exe -ArgumentList $argList -WorkingDirectory (Split-Path $exe) `
            -WindowStyle Hidden -PassThru -RedirectStandardOutput $LogOut -RedirectStandardError $LogErr
    } catch {
        Show-Msg ("Impossible de lancer le serveur :`n" + $_.Exception.Message) 'Error'; return
    }
    $script:serverReady = $false
    $script:startedAt = Get-Date
    $lblSrv.Text = 'Serveur : chargement du modèle...'
    Set-UiState 'loading'
    $srvTimer.Start()
}

$srvTimer = New-Object System.Windows.Forms.Timer
$srvTimer.Interval = 1000
$srvTimer.Add_Tick({
    if ($script:proc -and $script:proc.HasExited) {
        $srvTimer.Stop()
        $code = $script:proc.ExitCode
        $tail = (Get-Content -Path $LogErr -Tail 10 -ErrorAction SilentlyContinue) -join "`n"
        $script:proc = $null
        Set-UiState 'stopped'
        Show-Msg "Le serveur s'est arrêté (code $code).`n`n$tail" 'Error'
        return
    }
    try {
        $r = [Net.HttpWebRequest]::Create("$ApiBase/health")
        $r.Timeout = 400
        $resp = $r.GetResponse(); $resp.Close()
        $srvTimer.Stop()
        $script:serverReady = $true
        Set-UiState 'ready'
        Add-Chat "Modèle chargé : $([IO.Path]::GetFileName($cbModel.Text)). Vous pouvez discuter.`n`n" ([System.Drawing.Color]::DimGray) 'Italic'
        $tbInput.Focus()
    } catch {
        $sec = [int]((Get-Date) - $script:startedAt).TotalSeconds
        $lblSrv.Text = "Serveur : chargement du modèle... ($sec s)"
    }
})

# --- Chat --------------------------------------------------------------------------------------
function Send-Message {
    if ($script:chatBusy) { return }
    if (-not $script:serverReady) { Show-Msg "Démarrez d'abord le serveur (modèle chargé)." 'Warning'; return }
    $txt = $tbInput.Text.Trim()
    if (-not $txt) { return }
    $tbInput.Clear()

    $trimmed = 0
    while ($script:lastTotal -gt (0.8 * $script:activeCtx) -and $script:history.Count -ge 2) {
        $dropped = 0
        foreach ($i in 1..2) { $dropped += $script:history[0].content.Length; $script:history.RemoveAt(0) }
        $script:lastTotal -= [int]($dropped / 3.5)
        $trimmed++
    }
    if ($trimmed) { Add-Chat "[Contexte presque plein : les plus anciens messages ont été oubliés pour continuer.]`n`n" ([System.Drawing.Color]::DarkOrange) 'Italic' }
    $script:history.Add(@{ role = 'user'; content = $txt })
    Add-Chat "Vous`n" ([System.Drawing.Color]::RoyalBlue) 'Bold'
    Add-Chat "$txt`n`n"
    Add-Chat "IA`n" ([System.Drawing.Color]::SeaGreen) 'Bold'

    $msgs = New-Object System.Collections.Generic.List[object]
    if ($tbSystem.Text.Trim()) { $msgs.Add(@{ role = 'system'; content = $tbSystem.Text.Trim() }) }
    foreach ($m in $script:history) { $msgs.Add($m) }
    $body = @{
        model = 'local'; messages = $msgs.ToArray(); stream = $true
        temperature = [double]$nudTemp.Value; max_tokens = [int]$nudMax.Value; stream_options = @{ include_usage = $true }
    }
    $json = ConvertTo-Json -InputObject $body -Depth 6 -Compress

    $script:chatBusy = $true
    $script:reply = ''
    $script:inThink = $false
    $script:chatSync = [hashtable]::Synchronized(@{
        queue = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]')
        done = $false; cancel = $false; req = $null
    })
    $btnSend.Enabled = $false; $btnStopGen.Enabled = $true
    $script:chatJob = Start-Bg $ChatScript @{ Sync = $script:chatSync; Url = "$ApiBase/v1/chat/completions"; Json = $json }
    $chatTimer.Start()
}

function Stop-Generation {
    if ($script:chatSync) {
        $script:chatSync.cancel = $true
        try { $script:chatSync.req.Abort() } catch {}
    }
}

$chatTimer = New-Object System.Windows.Forms.Timer
$chatTimer.Interval = 40
$chatTimer.Add_Tick({
    $s = $script:chatSync
    $item = $null
    $n = 0
    while ($n -lt 300 -and $s.queue.TryDequeue([ref]$item)) {
        $n++
        $kind = $item.Substring(0, 1)
        $t = $item.Substring(1)
        switch ($kind) {
            'C' {
                if ($script:inThink) { Add-Chat "`n"; $script:inThink = $false }
                Add-Chat $t
                $script:reply += $t
            }
            'R' {
                $script:inThink = $true
                Add-Chat $t ([System.Drawing.Color]::Gray) 'Italic'
            }
            'E' { Add-Chat "`n[Erreur] $t" ([System.Drawing.Color]::Firebrick) 'Bold' }
            'U' {
                $u = $t -split ';'
                $script:lastTotal = [int]$u[0] + [int]$u[1]
                $x = "Contexte : $($script:lastTotal) / $($script:activeCtx) tokens"
                if ($u.Count -gt 2 -and $u[2]) { $x += "   |   $($u[2]) tokens/s" }
                $script:statusExtra = $x
                Update-ReadyLabel
            }
        }
    }
    if ($s.done -and $s.queue.IsEmpty) {
        $chatTimer.Stop()
        Stop-Bg $script:chatJob
        $script:chatJob = $null
        if ($script:reply) { $script:history.Add(@{ role = 'assistant'; content = $script:reply }) }
        elseif ($script:history.Count -gt 0) { $script:history.RemoveAt($script:history.Count - 1) }
        Add-Chat "`n`n"
        $script:chatBusy = $false
        $btnStopGen.Enabled = $false
        $btnSend.Enabled = $script:serverReady
        $tbInput.Focus()
    }
})

# --- Téléchargements ---------------------------------------------------------------------------
function Start-Download {
    param([string]$Kind, [string]$Body, [hashtable]$Params)
    if ($script:dlBusy) { return }
    $script:dlBusy = $true
    $script:dlKind = $Kind
    $script:dlSync = [hashtable]::Synchronized(@{
        pct = 0; text = 'Démarrage...'; label = ''; done = $false; error = $null; result = $null; cancel = $false
    })
    $pb.Value = 0
    $lblDl.ForeColor = [System.Drawing.Color]::Black
    foreach ($b in $btnDlEngine, $btnDlModel, $btnStart) { $b.Enabled = $false }
    $btnCancelDl.Enabled = $true
    $script:dlJob = Start-Bg ($DownloadFn + "`n" + $Body) ($Params + @{ Sync = $script:dlSync })
    $dlTimer.Start()
}

$dlTimer = New-Object System.Windows.Forms.Timer
$dlTimer.Interval = 200
$dlTimer.Add_Tick({
    $s = $script:dlSync
    $pb.Value = [Math]::Min(100, [Math]::Max(0, [int]$s.pct))
    $lblDl.Text = $s.text
    if ($s.done) {
        $dlTimer.Stop()
        Stop-Bg $script:dlJob
        $script:dlJob = $null
        $script:dlBusy = $false
        $btnDlEngine.Enabled = $true; $btnDlModel.Enabled = $true; $btnCancelDl.Enabled = $false
        $btnStart.Enabled = (-not $script:proc)
        if ($s.error) {
            $lblDl.ForeColor = [System.Drawing.Color]::Firebrick
            $lblDl.Text = 'Échec : ' + $s.error
            if ($s.error -ne 'Annulé') { Show-Msg ("Échec du téléchargement :`n" + $s.error) 'Error' }
        } else {
            $lblDl.ForeColor = [System.Drawing.Color]::SeaGreen
            $lblDl.Text = 'Terminé.'
            if ($script:dlKind -eq 'engine') { $tbServer.Text = $s.result }
            else { Update-ModelList; $cbModel.SelectedItem = $s.result }
        }
    }
})

# --- Événements --------------------------------------------------------------------------------
$btnDlEngine.Add_Click({
    if ($script:proc) { Stop-Server }
    Start-Download 'engine' $EngineScript @{ BinDir = $BinDir; Backend = [string]$cbBackend.SelectedItem }
})

$btnDlModel.Add_Click({
    $url = $tbUrl.Text.Trim()
    if ($url -notmatch '^https?://') { Show-Msg "Saisissez une URL valide (https://...)." 'Warning'; return }
    if ($url -match '^https?://huggingface\.co/.+/blob/') { $url = $url -replace '/blob/', '/resolve/' }
    $name = [Uri]::UnescapeDataString([IO.Path]::GetFileName(([Uri]$url).AbsolutePath))
    if ($name -notlike '*.gguf') { Show-Msg "L'URL doit pointer vers un fichier .gguf." 'Warning'; return }
    $dest = Join-Path $ModelDir $name
    if (Test-Path $dest) {
        $r = [System.Windows.Forms.MessageBox]::Show($form, "$name existe déjà. Le télécharger de nouveau ?", 'GGUF Chat', 'YesNo', 'Question')
        if ($r -ne 'Yes') { return }
        if ($script:proc) { Stop-Server }
    }
    Start-Download 'model' $ModelScript @{ Url = $url; Dest = $dest; Token = $tbToken.Text.Trim() }
})

$btnCancelDl.Add_Click({ if ($script:dlSync) { $script:dlSync.cancel = $true } })

$btnSrvBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'llama-server.exe|llama-server.exe|Exécutables (*.exe)|*.exe'
    if ($dlg.ShowDialog() -eq 'OK') { $tbServer.Text = $dlg.FileName }
})

$btnMdlBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Modèles GGUF (*.gguf)|*.gguf'
    if ($dlg.ShowDialog() -eq 'OK') {
        if (-not $cbModel.Items.Contains($dlg.FileName)) { [void]$cbModel.Items.Add($dlg.FileName) }
        $cbModel.SelectedItem = $dlg.FileName
    }
})

$btnRefresh.Add_Click({ Update-ModelList })
$btnOpenDir.Add_Click({ Start-Process explorer.exe $ModelDir })
$btnStart.Add_Click({ Start-Server })
$btnStop.Add_Click({ Stop-Server })
$btnLog.Add_Click({
    if (Test-Path $LogErr) { Start-Process notepad.exe $LogErr } else { Show-Msg 'Aucun journal pour le moment.' }
})
$btnSend.Add_Click({ Send-Message })
$btnStopGen.Add_Click({ Stop-Generation })
$btnClear.Add_Click({
    if (-not $script:chatBusy) {
        $script:history.Clear(); $chatBox.Clear(); $script:lastTotal = 0; $script:statusExtra = ''
        if ($script:serverReady) { Update-ReadyLabel }
    }
})
$tbInput.Add_KeyDown({
    param($sender, $e)
    if ($e.KeyCode -eq 'Return' -and -not $e.Shift) { $e.SuppressKeyPress = $true; Send-Message }
})

# Profils de contexte et estimation mémoire
$btnAuto.Add_Click({ Set-AutoGpu })
$cbProfile.Add_SelectedIndexChanged({
    $p = [string]$cbProfile.SelectedItem
    if ($p -eq 'Personnalisé') { return }
    $script:suspend = $true
    switch ($p) {
        'Équilibré (8k)'  { $nudCtx.Value = 8192;   $cbKv.SelectedItem = 'f16';  $chkFa.Checked = $true; $chkNkvo.Checked = $false }
        'Long (16k)'      { $nudCtx.Value = 16384;  $cbKv.SelectedItem = 'q8_0'; $chkFa.Checked = $true; $chkNkvo.Checked = $false }
        'Très long (32k)' { $nudCtx.Value = 32768;  $cbKv.SelectedItem = 'q8_0'; $chkFa.Checked = $true; $chkNkvo.Checked = $true }
        'Ultra (64k)'     { $nudCtx.Value = 65536;  $cbKv.SelectedItem = 'q8_0'; $chkFa.Checked = $true; $chkNkvo.Checked = $true }
        'Extrême (128k)'  { $nudCtx.Value = 131072; $cbKv.SelectedItem = 'q4_0'; $chkFa.Checked = $true; $chkNkvo.Checked = $true }
    }
    $script:suspend = $false
    if ($cbModel.Text) { Set-AutoGpu } else { Update-Estimate }
})
$nudCtx.Add_ValueChanged({ if (-not $script:suspend) { $cbProfile.SelectedIndex = 0 }; Update-Estimate })
$cbKv.Add_SelectedIndexChanged({
    if ([string]$cbKv.SelectedItem -ne 'f16') { $chkFa.Checked = $true }
    Update-Estimate
})
$nudNgl.Add_ValueChanged({ Update-Estimate })
$nudVram.Add_ValueChanged({ Update-Estimate })
$chkNkvo.Add_CheckedChanged({ Update-Estimate })
$cbModel.Add_SelectedIndexChanged({ Update-Estimate })

$form.Add_FormClosing({
    $dlTimer.Stop(); $chatTimer.Stop()
    if ($script:dlSync) { $script:dlSync.cancel = $true }
    Stop-Server
})

$form.Add_Shown({
    Update-ModelList
    $found = Get-ChildItem -Path $BinDir -Recurse -Filter 'llama-server.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { $tbServer.Text = $found.FullName }
    Set-UiState 'stopped'
    Update-Estimate
    Add-Chat "Bienvenue dans GGUF Chat`n" ([System.Drawing.Color]::DimGray) 'Bold'
    Add-Chat ("1. Cliquez sur « Télécharger llama.cpp » (une seule fois) ou indiquez votre llama-server.exe.`n" +
              "2. Collez l'URL d'un fichier .gguf puis « Télécharger le modèle » (ou choisissez un fichier local avec « ... »).`n" +
              "3. Choisissez un profil de contexte puis « Auto-régler GPU » (adapte les couches à votre VRAM).`n" +
              "4. Cliquez sur « Démarrer le serveur », attendez le message vert, puis discutez.`n`n") ([System.Drawing.Color]::DimGray) 'Italic'
})

[void]$form.ShowDialog()