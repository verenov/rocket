param(
    [int]$MoveTime = 3000,
    [int]$Threads = 8,
    [int]$Runs = 3,
    [int]$Hash = 64,
    [string]$Engine = (Join-Path $PSScriptRoot 'zig-out\bin\rocket.exe')
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Engine)) {
    throw "Engine not found: $Engine"
}

$positions = @(
    [pscustomobject]@{
        Name = 'Start'
        Command = 'position startpos'
    },
    [pscustomobject]@{
        Name = 'Opening'
        Command = 'position fen r1bqk2r/pppp1ppp/2n2n2/2b1p3/4P3/2N2N2/PPPP1PPP/R1BQKB1R w KQkq - 4 5'
    },
    [pscustomobject]@{
        Name = 'Middlegame'
        Command = 'position fen r4rk1/1pp1qppp/p1np1n2/8/2B1P3/2N1B3/PPP2PPP/R2Q1RK1 w - - 0 10'
    },
    [pscustomobject]@{
        Name = 'Tactical'
        Command = 'position fen r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1'
    },
    [pscustomobject]@{
        Name = 'Endgame'
        Command = 'position fen 8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1'
    }
)

function Invoke-RocketSearch {
    param([string]$PositionCommand)

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Engine
    $startInfo.WorkingDirectory = Split-Path -Parent $Engine
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw 'Failed to start Rocket' }

    $stderrTask = $process.StandardError.ReadToEndAsync()

    $process.StandardInput.WriteLine("setoption name Hash value $Hash")
    $process.StandardInput.WriteLine("setoption name Threads value $Threads")
    $process.StandardInput.WriteLine('setoption name Use NNUE value true')
    $process.StandardInput.WriteLine('ucinewgame')
    $process.StandardInput.WriteLine($PositionCommand)
    $process.StandardInput.WriteLine("go movetime $MoveTime")

    # UCI search is asynchronous so stop, ponderhit, and isready stay live.
    # Wait for bestmove before sending quit; queuing quit immediately would
    # correctly stop the new search and turn this into a near-zero-time run.
    $outputLines = [System.Collections.Generic.List[string]]::new()
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    $searchTimeout = [Math]::Max(10000, $MoveTime + 10000)
    $sawBestMove = $false
    while ($deadline.ElapsedMilliseconds -lt $searchTimeout) {
        $remaining = [Math]::Max(1, $searchTimeout - [int]$deadline.ElapsedMilliseconds)
        $lineTask = $process.StandardOutput.ReadLineAsync()
        if (-not $lineTask.Wait($remaining)) {
            throw "Timed out waiting for bestmove"
        }
        $line = $lineTask.Result
        if ($null -eq $line) { break }
        $outputLines.Add($line)
        if ($line -match '^bestmove\b') {
            $sawBestMove = $true
            break
        }
    }
    if (-not $sawBestMove) {
        throw "Engine exited without bestmove"
    }

    $process.StandardInput.WriteLine('quit')
    $process.StandardInput.Close()

    $process.WaitForExit()
    $stdout = $outputLines -join "`n"
    $stderr = $stderrTask.Result
    $exitCode = $process.ExitCode
    $process.Dispose()

    if ($exitCode -ne 0) {
        throw "Rocket exited with code $exitCode`n$stderr"
    }

    $finalInfo = $null
    $bestMove = $null
    foreach ($line in ($stdout -split "`r?`n")) {
        if ($line -match '^info depth (?<depth>\d+) seldepth (?<seldepth>\d+) score (?<scoreType>cp|mate) (?<score>-?\d+) nodes (?<nodes>\d+) time (?<time>\d+) nps (?<nps>\d+)') {
            $finalInfo = [pscustomobject]@{
                Depth = [int]$Matches.depth
                SelDepth = [int]$Matches.seldepth
                Score = "$($Matches.scoreType) $($Matches.score)"
                Nodes = [uint64]$Matches.nodes
                Time = [uint64]$Matches.time
                Nps = [uint64]$Matches.nps
            }
        } elseif ($line -match '^bestmove (?<move>\S+)') {
            $bestMove = $Matches.move
        }
    }

    if ($null -eq $finalInfo) {
        throw "No final UCI info line found`n$stdout`n$stderr"
    }
    $finalInfo | Add-Member -NotePropertyName BestMove -NotePropertyValue $bestMove
    return $finalInfo
}

function Get-Median {
    param([object[]]$Values)
    $sorted = @($Values | Sort-Object)
    return $sorted[[Math]::Floor($sorted.Count / 2)]
}

$results = @()
Write-Host "Rocket NNUE benchmark: ${MoveTime}ms, $Threads threads, $Runs runs, ${Hash}MB hash"

foreach ($position in $positions) {
    $samples = @()
    for ($run = 1; $run -le $Runs; $run++) {
        $sample = Invoke-RocketSearch -PositionCommand $position.Command
        $samples += $sample
        Write-Host ("{0,-12} run {1}: depth {2,2}, {3,10:N0} nps, {4,12:N0} nodes, best {5}" -f `
            $position.Name, $run, $sample.Depth, $sample.Nps, $sample.Nodes, $sample.BestMove)
    }

    $depths = @($samples | ForEach-Object Depth)
    $npsValues = @($samples | ForEach-Object Nps)
    $nodeValues = @($samples | ForEach-Object Nodes)
    $results += [pscustomobject]@{
        Position = $position.Name
        MedianDepth = Get-Median $depths
        DepthRange = "$(($depths | Measure-Object -Minimum).Minimum)-$(($depths | Measure-Object -Maximum).Maximum)"
        MedianNps = Get-Median $npsValues
        MedianNodes = Get-Median $nodeValues
        BestMoves = (($samples | ForEach-Object BestMove | Sort-Object -Unique) -join ',')
    }
}

Write-Host ''
$results | Format-Table Position, MedianDepth, DepthRange, MedianNps, MedianNodes, BestMoves -AutoSize
