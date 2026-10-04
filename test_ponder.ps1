param(
    [string]$Engine = ".\zig-out\bin\rocket.exe"
)

$ErrorActionPreference = "Stop"
$enginePath = (Resolve-Path $Engine).Path
$process = $null

function Send-Uci([string]$Command) {
    $script:process.StandardInput.WriteLine($Command)
    $script:process.StandardInput.Flush()
}

function Read-UciLine([int]$TimeoutMs = 3000) {
    $task = $script:process.StandardOutput.ReadLineAsync()
    if (-not $task.Wait($TimeoutMs)) {
        throw "Timed out waiting for UCI output"
    }
    return $task.Result
}

function Read-Until([string]$Pattern, [int]$TimeoutMs = 3000, [switch]$RejectBestMove) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $matchingLine = $null
    while ($timer.ElapsedMilliseconds -lt $TimeoutMs) {
        $remaining = [Math]::Max(1, $TimeoutMs - [int]$timer.ElapsedMilliseconds)
        $line = Read-UciLine $remaining
        if ($RejectBestMove -and $line -match '^bestmove\b') {
            throw "Unexpected early bestmove: $line"
        }
        if ($line -match $Pattern) {
            $matchingLine = $line
            break
        }
    }
    if ($null -eq $matchingLine) {
        throw "Did not receive output matching: $Pattern"
    }
    return $matchingLine
}

try {
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $enginePath
    $startInfo.WorkingDirectory = (Get-Location).Path
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = [Diagnostics.Process]::Start($startInfo)

    Send-Uci "uci"
    $sawPonderOption = $false
    do {
        $line = Read-UciLine 3000
        if ($line -eq 'option name Ponder type check default false') {
            $sawPonderOption = $true
        }
    } while ($line -ne 'uciok')
    if (-not $sawPonderOption) {
        throw "UCI handshake did not advertise Ponder"
    }

    Send-Uci "setoption name Ponder value true"
    Send-Uci "setoption name Threads value 1"

    # Ponder time is free. It must remain responsive, emit no bestmove before
    # ponderhit, and then receive a fresh 300ms move budget.
    Send-Uci "position startpos moves e2e4 e7e5 g1f3 b8c6"
    Send-Uci "go ponder movetime 300"
    Start-Sleep -Milliseconds 700
    Send-Uci "isready"
    [void](Read-Until '^readyok$' 1500 -RejectBestMove)

    $hitTimer = [Diagnostics.Stopwatch]::StartNew()
    Send-Uci "ponderhit"
    $ponderResult = Read-Until '^bestmove\b' 3000
    $hitElapsed = $hitTimer.ElapsedMilliseconds
    if ($hitElapsed -lt 200) {
        throw "Ponder search reused an expired pre-hit clock (${hitElapsed}ms)"
    }
    if ($ponderResult -notmatch '\bponder\s+[a-h][1-8][a-h][1-8][qrbn]?') {
        throw "Ponder-enabled bestmove did not include a legal predicted reply: $ponderResult"
    }

    # Infinite analysis must also leave stdin live and stop exactly once.
    Send-Uci "position startpos moves d2d4 d7d5 c2c4"
    Send-Uci "go infinite"
    Start-Sleep -Milliseconds 250
    Send-Uci "isready"
    [void](Read-Until '^readyok$' 1500 -RejectBestMove)
    Send-Uci "stop"
    Send-Uci "isready"
    $bestMoves = 0
    do {
        $line = Read-UciLine 3000
        if ($line -match '^bestmove\b') { $bestMoves++ }
    } while ($line -ne 'readyok')
    if ($bestMoves -ne 1) {
        throw "Infinite stop emitted $bestMoves bestmove lines"
    }

    # A ponder miss is stopped without ponderhit and still returns one move.
    Send-Uci "go ponder movetime 100"
    Start-Sleep -Milliseconds 300
    Send-Uci "isready"
    [void](Read-Until '^readyok$' 1500 -RejectBestMove)
    Send-Uci "stop"
    Send-Uci "isready"
    $bestMoves = 0
    do {
        $line = Read-UciLine 3000
        if ($line -match '^bestmove\b') { $bestMoves++ }
    } while ($line -ne 'readyok')
    if ($bestMoves -ne 1) {
        throw "Ponder miss emitted $bestMoves bestmove lines"
    }

    # Stray ponderhit is harmless, and enabling Ponder does not change a
    # normal finite go command into an implicit ponder search.
    Send-Uci "ponderhit"
    Send-Uci "position startpos moves e2e4 c7c5"
    Send-Uci "go depth 1"
    [void](Read-Until '^bestmove\b' 3000)

    Send-Uci "quit"
    if (-not $process.WaitForExit(3000)) {
        throw "Engine did not exit after quit"
    }

    Write-Output "PASS: ponder option, ponderhit timing (${hitElapsed}ms), infinite stop, ponder miss, and normal go"
}
finally {
    if ($null -ne $process -and -not $process.HasExited) {
        $process.Kill()
        [void]$process.WaitForExit(1000)
    }
}
