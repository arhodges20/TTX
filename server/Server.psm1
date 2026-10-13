# TTX Control Center HTTP server. Windows PowerShell 5.1.
#
# A single-threaded HttpListener loop bound to http://localhost:<port>/. Between
# requests it calls Update-TtxEngine so background steps progress while the UI
# polls. Requires Engine.psm1 to be imported and initialized first.

$script:UiFiles = @{
    '/'           = @{ File = 'index.html'; Type = 'text/html' }
    '/index.html' = @{ File = 'index.html'; Type = 'text/html' }
    '/app.js'     = @{ File = 'app.js'; Type = 'application/javascript' }
    '/style.css'  = @{ File = 'style.css'; Type = 'text/css' }
    '/builder.js' = @{ File = 'builder.js'; Type = 'application/javascript' }
}

function Send-TtxResponse {
    param(
        [Parameter(Mandatory = $true)]$Response,
        [int]$Status = 200,
        [string]$ContentType = 'application/json',
        [AllowEmptyString()][string]$Body = ''
    )
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $Response.StatusCode = $Status
    $Response.ContentType = "$ContentType; charset=utf-8"
    $Response.Headers['Cache-Control'] = 'no-store'
    $Response.Headers['X-Content-Type-Options'] = 'nosniff'
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Send-TtxJson {
    param($Response, $Data, [int]$Status = 200)
    Send-TtxResponse -Response $Response -Status $Status -Body (ConvertTo-TtxJson -InputObject $Data -Compress)
}

function Read-TtxRequestBody {
    param($Request)
    if (-not $Request.HasEntityBody) { return @{} }
    if ($Request.ContentLength64 -gt 1048576) { throw (New-Object System.ArgumentException 'Request body too large.') }
    $reader = New-Object System.IO.StreamReader($Request.InputStream, [System.Text.Encoding]::UTF8)
    try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
    if ([string]::IsNullOrWhiteSpace($text)) { return @{} }
    try { $body = ConvertFrom-TtxJson -Json $text }
    catch { throw (New-Object System.ArgumentException 'Request body is not valid JSON.') }
    if ($body -isnot [hashtable]) { throw (New-Object System.ArgumentException 'Request body must be a JSON object.') }
    return $body
}

function Invoke-TtxRequest {
    param($Context, [string]$UiRoot, [int]$Port)

    $req = $Context.Request
    $res = $Context.Response
    $method = $req.HttpMethod
    $path = $req.Url.AbsolutePath
    try {
        # Only answer requests addressed to localhost (guards against DNS rebinding).
        $hostHeader = [string]$req.Headers['Host']
        if ($hostHeader -notmatch "^(localhost|127\.0\.0\.1)(:$Port)?$") {
            Send-TtxJson $res @{ error = 'Forbidden host.' } 403
            return
        }
        # State-changing requests must carry a custom header. Browsers won't send
        # it cross-origin without a CORS preflight, which this server never approves.
        if ($method -eq 'POST' -and $req.Headers['X-TTX-Request'] -ne '1') {
            Send-TtxJson $res @{ error = 'Missing X-TTX-Request header.' } 403
            return
        }

        if ($method -eq 'GET' -and $script:UiFiles.ContainsKey($path)) {
            $f = $script:UiFiles[$path]
            $text = [System.IO.File]::ReadAllText((Join-Path $UiRoot $f.File), [System.Text.Encoding]::UTF8)
            Send-TtxResponse -Response $res -ContentType $f.Type -Body $text
            return
        }

        if ($method -eq 'GET' -and $path -eq '/api/scenarios') {
            Send-TtxJson $res @{ scenarios = (Get-TtxScenarioList) }
            return
        }
        if ($method -eq 'GET' -and $path -match '^/api/scenarios/([A-Za-z0-9_-]+)$') {
            Send-TtxJson $res (Get-TtxScenario -Id $Matches[1])
            return
        }
        if ($method -eq 'GET' -and $path -eq '/api/preflight') {
            Send-TtxJson $res (Get-TtxHostPreflight)
            return
        }
        if ($method -eq 'GET' -and $path -eq '/api/catalog') {
            # Pre-serialized: the list can hold over a thousand tests.
            Send-TtxResponse -Response $res -Body (Get-TtxCatalogJson)
            return
        }
        if ($method -eq 'GET' -and $path -eq '/api/catalog/status') {
            Send-TtxJson $res (Get-TtxCatalogStatus)
            return
        }
        if ($method -eq 'GET' -and $path -match '^/api/catalog/tests/([0-9A-Fa-f-]{36})$') {
            $t = Get-TtxCatalogTest -Guid $Matches[1]
            if (-not $t) { Send-TtxJson $res @{ error = "Test $($Matches[1]) is not in the installed atomics." } 404; return }
            Send-TtxJson $res $t
            return
        }
        if ($method -eq 'GET' -and $path -eq '/api/session/answer-key') {
            $key = Get-TtxAnswerKey
            Send-TtxResponse -Response $res -ContentType 'text/markdown' -Body $key.markdown
            return
        }
        if ($method -eq 'GET' -and $path -eq '/api/session') {
            $since = 0
            $rev = -1
            [void][int]::TryParse([string]$req.QueryString['since'], [ref]$since)
            if ($req.QueryString['rev']) { [void][int]::TryParse([string]$req.QueryString['rev'], [ref]$rev) }
            Send-TtxJson $res (Get-TtxSessionView -Since $since -Revision $rev)
            return
        }

        if ($method -eq 'POST') {
            $body = Read-TtxRequestBody -Request $req
            Write-Host "$(Get-Date -Format 'HH:mm:ss') POST $path"
            if ($path -eq '/api/sessions') {
                $params = @{}
                if ($body.parameters -is [hashtable]) { $params = $body.parameters }
                Send-TtxJson $res (New-TtxSession -ScenarioId ([string]$body.scenarioId) -Parameters $params)
                return
            }
            if ($path -eq '/api/scenarios') {
                Send-TtxJson $res (Save-TtxScenario -Scenario $body.scenario -Overwrite ([bool]$body.overwrite))
                return
            }
            if ($path -eq '/api/catalog/rescan') {
                Start-TtxCatalogBuild
                Send-TtxJson $res (Get-TtxCatalogStatus)
                return
            }
            if ($path -eq '/api/catalog/preview') {
                $ia = @{}
                if ($body.input_arguments -is [hashtable]) { $ia = $body.input_arguments }
                Send-TtxJson $res (Get-TtxAtomicPreview -Guid ([string]$body.guid) -InputArguments $ia)
                return
            }
            if ($path -eq '/api/session/run-all') {
                Send-TtxJson $res (Start-TtxRunAll)
                return
            }
            if ($path -eq '/api/session/calibrate') {
                Send-TtxJson $res (Invoke-TtxCalibration)
                return
            }
            if ($path -eq '/api/session/calibration') {
                Send-TtxJson $res (Set-TtxCalibrationResult -Result ([string]$body.result) -Notes ([string]$body.notes))
                return
            }
            if ($path -eq '/api/session/cleanup') {
                Send-TtxJson $res (Start-TtxCleanup)
                return
            }
            if ($path -match '^/api/session/steps/([A-Za-z0-9_-]+)/run$') {
                Send-TtxJson $res (Start-TtxStep -StepId $Matches[1])
                return
            }
            if ($path -match '^/api/session/steps/([A-Za-z0-9_-]+)/getprereqs$') {
                Send-TtxJson $res (Start-TtxGetPrereqs -StepId $Matches[1] -Confirm ($body.confirm -eq $true) -ConfirmDownload ($body.confirmDownload -eq $true))
                return
            }
            if ($path -match '^/api/session/steps/([A-Za-z0-9_-]+)/detections$') {
                Send-TtxJson $res (Set-TtxDetectionResult -StepId $Matches[1] -DetectionId ([string]$body.detectionId) -Result ([string]$body.result) -Notes ([string]$body.notes))
                return
            }
        }

        Send-TtxJson $res @{ error = "Not found: $method $path" } 404
    }
    catch {
        $ex = $_.Exception
        $status = 500
        if ($ex -is [System.ArgumentException]) { $status = 400 }
        elseif ($ex -is [System.Collections.Generic.KeyNotFoundException]) { $status = 404 }
        elseif ($ex -is [System.InvalidOperationException]) { $status = 409 }
        if ($status -eq 500) { Write-Warning "$method $path failed: $($ex.Message)" }
        try { Send-TtxJson $res @{ error = $ex.Message } $status }
        catch { Write-Verbose "Could not send error response: $($_.Exception.Message)" }
    }
    finally {
        # The browser may have gone away; nothing more to do for this request.
        try { $res.Close() } catch { Write-Verbose "Could not close response: $($_.Exception.Message)" }
    }
}

function Start-TtxServer {
    param(
        [int]$Port = 8080,
        [Parameter(Mandatory = $true)][string]$UiRoot,
        [switch]$OpenBrowser
    )
    $prefix = "http://localhost:$Port/"
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add($prefix)
    try {
        $listener.Start()
    }
    catch {
        throw "Could not listen on $prefix : $($_.Exception.Message). Is another program using port $Port? Try -Port <other>."
    }

    Write-Host "TTX Control Center is running at $prefix" -ForegroundColor Green
    Write-Host 'Press Ctrl+C to stop.'
    if ($OpenBrowser) { Start-Process $prefix }

    $pending = $null
    try {
        while ($listener.IsListening) {
            if ($null -eq $pending) { $pending = $listener.GetContextAsync() }
            if ($pending.Wait(250)) {
                $ctx = $pending.Result
                $pending = $null
                Invoke-TtxRequest -Context $ctx -UiRoot $UiRoot -Port $Port
            }
            try { Update-TtxEngine }
            catch { Write-Warning "Engine update failed: $($_.Exception.Message)" }
        }
    }
    finally {
        Write-Host 'Stopping TTX Control Center...'
        Stop-TtxEngine
        $listener.Stop()
        $listener.Close()
    }
}

Export-ModuleMember -Function Start-TtxServer
