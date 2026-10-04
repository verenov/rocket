param(
    [string]$Candidate = ".\zig-out\bin\rocket.exe",
    [string]$Baseline = ".\selfplay\rocket_baseline.exe",
    [int]$StartGame = 0,
    [int]$Games = 32,
    [int]$Nodes = 50000,
    [ValidateSet("nodes", "sudden", "fischer", "movestogo")]
    [string]$TimeMode = "nodes",
    [int]$InitialTimeMs = 1000,
    [int]$IncrementMs = 20,
    [int]$MovesPerControl = 20,
    [int]$RefillTimeMs = 1000,
    [int]$Threads = 1,
    [int]$Hash = 64,
    [int]$MaxPlies = 180,
    [int]$MoveTimeoutMs = 30000,
    [string]$Output = ".\selfplay\last_match.csv"
)

$ErrorActionPreference = "Stop"
$candidatePath = (Resolve-Path $Candidate).Path
$baselinePath = (Resolve-Path $Baseline).Path

$openings = @(
    "",
    "e2e4 e7e5 g1f3 b8c6 f1b5",
    "e2e4 c7c5 g1f3 d7d6 d2d4 c5d4 f3d4",
    "e2e4 e7e6 d2d4 d7d5 b1c3",
    "e2e4 c7c6 d2d4 d7d5 e4e5",
    "d2d4 g8f6 c2c4 e7e6 b1c3 f8b4",
    "d2d4 d7d5 c2c4 e7e6 b1c3 g8f6",
    "c2c4 e7e5 b1c3 g8f6 g2g3",
    "g1f3 d7d5 g2g3 g8f6 f1g2",
    "e2e4 g8f6 e4e5 f6d5 d2d4",
    "d2d4 g8f6 c2c4 g7g6 b1c3 f8g7",
    "e2e4 c7c5 b1c3 b8c6 f2f4",
    "d2d4 f7f5 g2g3 g8f6 f1g2",
    "c2c4 g8f6 b1c3 e7e5 g2g3",
    "e2e4 d7d5 e4d5 d8d5 b1c3",
    "d2d4 g8f6 g1f3 e7e6 e2e3",
    "e2e4 e7e5 f2f4 e5f4 g1f3",
    "e2e4 c7c5 g1f3 b8c6 d2d4 c5d4 f3d4",
    "d2d4 g8f6 c2c4 c7c5 d4d5 e7e6",
    "c2c4 c7c5 g1f3 g8f6 d2d4 c5d4 f3d4",
    "g1f3 g8f6 c2c4 g7g6 b1c3 f8g7",
    "e2e4 e7e5 g1f3 g8f6 f3e5",
    "d2d4 d7d5 g1f3 g8f6 c2c4",
    "e2e4 c7c5 g1f3 e7e6 d2d4 c5d4 f3d4"
)

function Start-UciEngine([string]$Path, [string]$Name) {
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Path
    $startInfo.WorkingDirectory = (Get-Location).Path
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = [Diagnostics.Process]::Start($startInfo)
    $engine = [pscustomobject]@{
        Name = $Name
        Process = $process
        StderrTask = $process.StandardError.ReadToEndAsync()
    }

    Send-Uci $engine "uci"
    [void](Read-Until $engine '^uciok$' 10000)
    Send-Uci $engine "setoption name Hash value $Hash"
    Send-Uci $engine "setoption name Threads value $Threads"
    Send-Uci $engine "setoption name Use NNUE value true"
    Send-Uci $engine "setoption name Ponder value false"
    Send-Uci $engine "isready"
    [void](Read-Until $engine '^readyok$' 10000)
    return $engine
}

function Send-Uci($Engine, [string]$Command) {
    $Engine.Process.StandardInput.WriteLine($Command)
    $Engine.Process.StandardInput.Flush()
}

function Read-Line($Engine, [int]$TimeoutMs) {
    $task = $Engine.Process.StandardOutput.ReadLineAsync()
    if (-not $task.Wait($TimeoutMs)) {
        throw "$($Engine.Name) timed out waiting for output"
    }
    if ($null -eq $task.Result) {
        throw "$($Engine.Name) closed stdout unexpectedly"
    }
    return $task.Result
}

function Read-Until($Engine, [string]$Pattern, [int]$TimeoutMs) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.ElapsedMilliseconds -lt $TimeoutMs) {
        $remaining = [Math]::Max(1, $TimeoutMs - [int]$timer.ElapsedMilliseconds)
        $line = Read-Line $Engine $remaining
        if ($line -match '^info string command error:') {
            throw "$($Engine.Name): $line"
        }
        if ($line -match $Pattern) { return $line }
    }
    throw "$($Engine.Name) did not produce output matching $Pattern"
}

function Invoke-Search(
    $Engine,
    [System.Collections.Generic.List[string]]$Moves,
    [long]$WhiteClock,
    [long]$BlackClock,
    [int]$MovesToGo
) {
    $position = if ($Moves.Count -eq 0) {
        "position startpos"
    } else {
        "position startpos moves " + ($Moves -join ' ')
    }
    Send-Uci $Engine $position
    if ($TimeMode -ne "nodes") {
        Send-Uci $Engine "isready"
        [void](Read-Until $Engine '^readyok$' 10000)
    }
    $goCommand = switch ($TimeMode) {
        "nodes" { "go nodes $Nodes" }
        "sudden" { "go wtime $WhiteClock btime $BlackClock" }
        "fischer" { "go wtime $WhiteClock btime $BlackClock winc $IncrementMs binc $IncrementMs" }
        "movestogo" { "go wtime $WhiteClock btime $BlackClock movestogo $MovesToGo" }
    }
    $moveTimer = [Diagnostics.Stopwatch]::StartNew()
    Send-Uci $Engine $goCommand

    $timer = [Diagnostics.Stopwatch]::StartNew()
    $scoreType = "cp"
    $score = 0
    $depth = 0
    $bestMove = $null
    while ($timer.ElapsedMilliseconds -lt $MoveTimeoutMs) {
        $remaining = [Math]::Max(1, $MoveTimeoutMs - [int]$timer.ElapsedMilliseconds)
        $line = Read-Line $Engine $remaining
        if ($line -match '^info string command error:') {
            throw "$($Engine.Name): $line"
        }
        if ($line -match '^info depth (?<depth>\d+) seldepth \d+ score (?<type>cp|mate) (?<score>-?\d+)') {
            $depth = [int]$Matches.depth
            $scoreType = $Matches.type
            $score = [int]$Matches.score
        } elseif ($line -match '^bestmove (?<move>\S+)') {
            $bestMove = $Matches.move
            break
        }
    }
    if ($null -eq $bestMove) {
        throw "$($Engine.Name) did not return bestmove within ${MoveTimeoutMs}ms"
    }
    $moveTimer.Stop()
    return [pscustomobject]@{
        Move = $bestMove
        ScoreType = $scoreType
        Score = $score
        Depth = $depth
        ElapsedMs = $moveTimer.ElapsedMilliseconds
    }
}

function Stop-UciEngine($Engine) {
    if ($null -eq $Engine -or $Engine.Process.HasExited) { return }
    try {
        Send-Uci $Engine "quit"
        if (-not $Engine.Process.WaitForExit(3000)) { $Engine.Process.Kill() }
    } catch {
        if (-not $Engine.Process.HasExited) { $Engine.Process.Kill() }
    }
    [void]$Engine.Process.WaitForExit(1000)
    $Engine.Process.Dispose()
}

function Get-Stats([System.Collections.Generic.List[double]]$Scores) {
    $count = $Scores.Count
    if ($count -eq 0) {
        return [pscustomobject]@{ Mean = 0.5; Low = 0.0; High = 1.0; Elo = 0.0 }
    }
    $mean = ($Scores | Measure-Object -Average).Average
    $variance = 0.0
    if ($count -gt 1) {
        foreach ($value in $Scores) { $variance += [Math]::Pow($value - $mean, 2) }
        $variance /= ($count - 1)
    }
    # Keep a small uncertainty floor so an all-draw opening sample does not
    # claim perfect certainty after only a few games.
    $variance = [Math]::Max($variance, 0.25 / ($count + 2))
    $se = [Math]::Sqrt($variance / $count)
    $low = [Math]::Max(0.0, $mean - 1.96 * $se)
    $high = [Math]::Min(1.0, $mean + 1.96 * $se)
    $bounded = [Math]::Min(0.999, [Math]::Max(0.001, $mean))
    $elo = -400.0 * [Math]::Log10((1.0 / $bounded) - 1.0)
    return [pscustomobject]@{ Mean = $mean; Low = $low; High = $high; Elo = $elo }
}

$candidateEngine = $null
$baselineEngine = $null
$candidateWins = 0
$baselineWins = 0
$draws = 0
$scores = [System.Collections.Generic.List[double]]::new()
$records = [System.Collections.Generic.List[object]]::new()

try {
    $candidateEngine = Start-UciEngine $candidatePath "candidate"
    $baselineEngine = Start-UciEngine $baselinePath "baseline"

    for ($localGame = 0; $localGame -lt $Games; $localGame++) {
        $game = $StartGame + $localGame
        Send-Uci $candidateEngine "ucinewgame"
        Send-Uci $baselineEngine "ucinewgame"

        $candidateIsWhite = ($game % 2 -eq 0)
        $openingIndex = [Math]::Floor($game / 2) % $openings.Count
        $moves = [System.Collections.Generic.List[string]]::new()
        if ($openings[$openingIndex].Length -gt 0) {
            foreach ($move in ($openings[$openingIndex] -split ' ')) { $moves.Add($move) }
        }

        $whiteBad = 0
        $blackBad = 0
        $drawStreak = 0
        [long]$whiteClock = $InitialTimeMs
        [long]$blackClock = $InitialTimeMs
        $whiteMovesToGo = [Math]::Max(1, $MovesPerControl)
        $blackMovesToGo = [Math]::Max(1, $MovesPerControl)
        [long]$candidateThinkMs = 0
        [long]$baselineThinkMs = 0
        $clockTrace = [System.Collections.Generic.List[string]]::new()
        $winner = "draw"
        $reason = "max plies"

        while ($moves.Count -lt $MaxPlies) {
            $whiteToMove = ($moves.Count % 2 -eq 0)
            $candidateTurn = if ($whiteToMove) { $candidateIsWhite } else { -not $candidateIsWhite }
            $engine = if ($candidateTurn) { $candidateEngine } else { $baselineEngine }
            $preMoveClock = if ($whiteToMove) { $whiteClock } else { $blackClock }
            if ($TimeMode -ne "nodes" -and $preMoveClock -le 0) {
                $winner = if ($candidateTurn) { "baseline" } else { "candidate" }
                $reason = "time"
                break
            }
            $movesToGo = if ($whiteToMove) { $whiteMovesToGo } else { $blackMovesToGo }
            $search = Invoke-Search $engine $moves $whiteClock $blackClock $movesToGo
            if ($candidateTurn) { $candidateThinkMs += $search.ElapsedMs } else { $baselineThinkMs += $search.ElapsedMs }
            if ($TimeMode -ne "nodes") {
                $sideLabel = if ($whiteToMove) { "w" } else { "b" }
                $clockTrace.Add("$($moves.Count):${sideLabel}:$preMoveClock`:$($search.ElapsedMs):$([Math]::Max(0, $preMoveClock - $search.ElapsedMs)):$movesToGo")
            }

            # Clock expires before increment or stage refill is awarded. The
            # time manager deliberately keeps a scheduling reserve, so no GUI
            # grace is added here.
            if ($TimeMode -ne "nodes") {
                if ($search.ElapsedMs -gt $preMoveClock) {
                    $winner = if ($candidateTurn) { "baseline" } else { "candidate" }
                    $reason = "time"
                    break
                }
                if ($whiteToMove) {
                    $whiteClock -= $search.ElapsedMs
                } else {
                    $blackClock -= $search.ElapsedMs
                }
            }

            $validMove = $search.Move -match '^[a-h][1-8][a-h][1-8][qrbn]?$' -and
                $search.Move.Substring(0, 2) -ne $search.Move.Substring(2, 2)
            if (-not $validMove) {
                if ($search.ScoreType -eq 'mate' -and $search.Score -le 0) {
                    $winner = if ($candidateTurn) { "baseline" } else { "candidate" }
                    $reason = "checkmate"
                } else {
                    $reason = "stalemate/terminal"
                }
                break
            }

            if ($search.ScoreType -eq 'cp' -and $search.Score -le -900) {
                if ($whiteToMove) { $whiteBad++ } else { $blackBad++ }
            } else {
                if ($whiteToMove) { $whiteBad = 0 } else { $blackBad = 0 }
            }
            if (($whiteToMove -and $whiteBad -ge 4) -or (-not $whiteToMove -and $blackBad -ge 4)) {
                $winner = if ($candidateTurn) { "baseline" } else { "candidate" }
                $reason = "resignation"
                break
            }

            if ($search.ScoreType -eq 'cp' -and [Math]::Abs($search.Score) -le 12 -and $moves.Count -ge 80) {
                $drawStreak++
            } else {
                $drawStreak = 0
            }
            if ($drawStreak -ge 20) {
                $reason = "draw adjudication"
                break
            }

            if ($TimeMode -eq "fischer") {
                if ($whiteToMove) { $whiteClock += $IncrementMs } else { $blackClock += $IncrementMs }
            } elseif ($TimeMode -eq "movestogo") {
                if ($whiteToMove) {
                    $whiteMovesToGo--
                    if ($whiteMovesToGo -eq 0) {
                        $whiteClock += $RefillTimeMs
                        $whiteMovesToGo = [Math]::Max(1, $MovesPerControl)
                    }
                } else {
                    $blackMovesToGo--
                    if ($blackMovesToGo -eq 0) {
                        $blackClock += $RefillTimeMs
                        $blackMovesToGo = [Math]::Max(1, $MovesPerControl)
                    }
                }
            }

            $moves.Add($search.Move)
        }

        $score = if ($winner -eq "candidate") {
            $candidateWins++
            1.0
        } elseif ($winner -eq "baseline") {
            $baselineWins++
            0.0
        } else {
            $draws++
            0.5
        }
        $scores.Add($score)
        $records.Add([pscustomobject]@{
            Game = $game + 1
            Opening = $openingIndex
            CandidateColor = if ($candidateIsWhite) { "white" } else { "black" }
            Result = $winner
            Reason = $reason
            Plies = $moves.Count
            TimeMode = $TimeMode
            WhiteClockMs = $whiteClock
            BlackClockMs = $blackClock
            CandidateThinkMs = $candidateThinkMs
            BaselineThinkMs = $baselineThinkMs
            ClockTrace = $clockTrace -join ';'
            Moves = $moves -join ' '
        })

        $stats = Get-Stats $scores
        Write-Host ("game {0,3}: {1,-9} ({2,-17})  W-L-D {3}-{4}-{5}  score {6:P1}  95% [{7:P1}, {8:P1}]" -f `
            ($game + 1), $winner, $reason, $candidateWins, $baselineWins, $draws, $stats.Mean, $stats.Low, $stats.High)
    }

    $outputDirectory = Split-Path -Parent $Output
    if ($outputDirectory) { New-Item -ItemType Directory -Force $outputDirectory | Out-Null }
    $records | Export-Csv -NoTypeInformation -Encoding UTF8 $Output

    $final = Get-Stats $scores
    Write-Host ""
    Write-Host ("FINAL W-L-D: {0}-{1}-{2}; candidate score {3:P2}; 95% CI [{4:P2}, {5:P2}]; estimated Elo {6:+0.0;-0.0;0.0}" -f `
        $candidateWins, $baselineWins, $draws, $final.Mean, $final.Low, $final.High, $final.Elo)
    if ($Games -ge 40 -and $final.Mean -ge 0.55 -and $final.Low -gt 0.50) {
        Write-Host "PASS: candidate beats the frozen baseline consistently"
    } else {
        Write-Host "INCONCLUSIVE: more games or another strength change is required"
    }
}
finally {
    Stop-UciEngine $candidateEngine
    Stop-UciEngine $baselineEngine
}
